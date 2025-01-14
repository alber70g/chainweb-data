{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
-- |

module ChainwebDb.Queries where

------------------------------------------------------------------------------
import           Data.Aeson hiding (Error)
import           Data.ByteString.Lazy (ByteString)
import           Data.Int
import           Data.Maybe (maybeToList)
import           Data.Text (Text)
import           Data.Time
import           Database.Beam hiding (insert)
import           Database.Beam.Postgres
import           Database.Beam.Postgres.Syntax
import           Database.Beam.Backend.SQL.SQL92
import           Database.Beam.Backend.SQL
------------------------------------------------------------------------------
import           Chainweb.Api.ChainId
import           Chainweb.Api.Common (BlockHeight)
import           ChainwebData.Api
import           ChainwebData.Pagination
import           ChainwebDb.BoundedScan
import           ChainwebDb.Database
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Event
import           ChainwebDb.Types.Transaction
import           ChainwebDb.Types.Transfer
import ChainwebDb.Types.Common (ReqKeyOrCoinbase)
------------------------------------------------------------------------------

type PgSelect a = SqlSelect Postgres (QExprToIdentity a)
type PgExpr s = QGenExpr QValueContext Postgres s
type PgBaseExpr = PgExpr QBaseScope

-- | A subset of the TransactionT record, used with beam for querying the
-- /txs/search endpoint response payload
data DbTxSummaryT f = DbTxSummary
  { dtsChainId :: C f Int64
  , dtsHeight :: C f Int64
  , dtsBlock :: C f (DbHash BlockHash)
  , dtsCreationTime :: C f UTCTime
  , dtsReqKey :: C f (DbHash TxHash)
  , dtsSender :: C f Text
  , dtsCode :: C f (Maybe Text)
  , dtsContinuation :: C f (Maybe (PgJSONB Value))
  , dtsGoodResult :: C f (Maybe (PgJSONB Value))
  } deriving (Generic, Beamable)

type DbTxSummary = DbTxSummaryT Identity

data TxCursorT f = TxCursor
  { txcHeight :: C f Int64
  , txcReqKey :: C f (DbHash TxHash)
  } deriving (Generic, Beamable)

type TxCursor = TxCursorT Identity

toTxSearchCursor :: DbTxSummaryT f -> TxCursorT (Directional f)
toTxSearchCursor DbTxSummary{..} = TxCursor
  (desc dtsHeight)
  (desc dtsReqKey)

toDbTxSummary :: TransactionT f -> DbTxSummaryT f
toDbTxSummary Transaction{..} = DbTxSummary
  { dtsChainId = _tx_chainId
  , dtsHeight = _tx_height
  , dtsBlock = unBlockId _tx_block
  , dtsCreationTime = _tx_creationTime
  , dtsReqKey = _tx_requestKey
  , dtsSender = _tx_sender
  , dtsCode = _tx_code
  , dtsContinuation = _tx_continuation
  , dtsGoodResult = _tx_goodResult
   }

txSearchSource ::
  Text ->
  Q Postgres ChainwebDataDb s (FilterMarked DbTxSummaryT (PgExpr s))
txSearchSource search = do
  tx <- all_ $ _cddb_transactions database
  let searchExp = val_ ("%" <> search <> "%")
      isMatch = fromMaybe_ (val_ "") (_tx_code tx) `like_` searchExp
  return $ FilterMarked isMatch $ toDbTxSummary tx

data EventSearchParams = EventSearchParams
  { espSearch :: Maybe Text
  , espParam :: Maybe EventParam
  , espName :: Maybe EventName
  , espModuleName :: Maybe EventModuleName
  }

eventSearchCond ::
  EventSearchParams ->
  EventT (PgExpr s) ->
  PgExpr s Bool
eventSearchCond EventSearchParams{..} ev = foldr (&&.) (val_ True) $
  concat [searchCond, qualNameCond, paramCond, moduleCond]
  where
    searchString search = "%" <> search <> "%"
    searchCond = fromMaybeArg espSearch $ \s ->
      (_ev_qualName ev `like_` val_ (searchString s)) ||.
      (_ev_paramText ev `like_` val_ (searchString s))
    qualNameCond = fromMaybeArg espName $ \(EventName n) ->
      _ev_qualName ev `like_` val_ (searchString n)
    paramCond = fromMaybeArg espParam $ \(EventParam p) ->
      _ev_paramText ev `like_` val_ (searchString p)
    moduleCond = fromMaybeArg espModuleName $ \(EventModuleName m) ->
      _ev_module ev ==. val_ m
    fromMaybeArg mbA f = f <$> maybeToList mbA

data EventCursorT f = EventCursor
  { ecHeight :: C f Int64
  , ecReqKey :: C f ReqKeyOrCoinbase
  , ecIdx :: C f Int64
  } deriving (Generic, Beamable)

type EventCursor = EventCursorT Identity
deriving instance Show EventCursor

type EventQueryStart = Maybe BlockHeight

toEventsSearchCursor :: EventT f -> EventCursorT (Directional f)
toEventsSearchCursor Event{..} = EventCursor
  (desc _ev_height)
  (desc _ev_requestkey)
  (asc _ev_idx)

eventsSearchSource ::
  EventSearchParams ->
  EventQueryStart ->
  Q Postgres ChainwebDataDb s (FilterMarked EventT (PgExpr s))
eventsSearchSource esp mbHeight = do
  ev <- all_ $ _cddb_events database
  whenArg mbHeight $ \hgt -> guard_ $
    _ev_height ev >=. val_ (fromIntegral hgt)
  return $ FilterMarked (eventSearchCond esp ev) ev

newtype EventSearchExtrasT f = EventSearchExtras
  { eseBlockTime :: C f UTCTime
  } deriving (Generic, Beamable)

eventSearchExtras ::
  EventT (PgExpr s) ->
  Q Postgres ChainwebDataDb s (EventSearchExtrasT (PgExpr s))
eventSearchExtras ev = do
  blk <- all_ $ _cddb_blocks database
  guard_ $ _ev_block ev `references_` blk
  return $ EventSearchExtras
    { eseBlockTime = _block_creationTime blk
    }

_bytequery :: Sql92SelectSyntax (BeamSqlBackendSyntax be) ~ PgSelectSyntax => SqlSelect be a -> ByteString
_bytequery = \case
  SqlSelect s -> pgRenderSyntaxScript $ fromPgSelect s

data AccountQueryStart
  = AQSNewQuery (Maybe BlockHeight) Offset
  | AQSContinue BlockHeight ReqKeyOrCoinbase Int

accountQueryStmt
    :: Limit
    -> Text
    -> Text
    -> Maybe ChainId
    -> AccountQueryStart
    -> SqlSelect
    Postgres
    (QExprToIdentity
    (TransferT (QGenExpr QValueContext Postgres QBaseScope)), UTCTime)
accountQueryStmt (Limit limit) account token chain aqs =
  select $
  limit_ limit $
  offset_ offset $
  orderBy_ getOrder $ do
    unionAll_ (accountQuery _tr_from_acct) (accountQuery _tr_to_acct)
  where
    getOrder (tr,_) =
      ( desc_ $ _tr_height tr
      , desc_ $ _tr_requestkey tr
      , asc_ $ _tr_idx tr)
    subQueryLimit = limit + offset
    accountQuery accountField = limit_ subQueryLimit $ orderBy_ getOrder $ do
      tr <- all_ (_cddb_transfers database)
      blk <- all_ (_cddb_blocks database)
      guard_ (_tr_block tr `references_` blk)
      guard_ $ accountField tr ==. val_ account
      guard_ $ _tr_modulename tr ==. val_ token
      whenArg chain $ \(ChainId c) -> guard_ $ _tr_chainid tr ==. fromIntegral c
      rowFilter tr
      return (tr,_block_creationTime blk)
    (Offset offset, rowFilter) = case aqs of
      AQSNewQuery mbHeight ofst -> (,) ofst $ \tr ->
        whenArg mbHeight $ \bh -> guard_ $ _tr_height tr <=. val_ (fromIntegral bh)
      AQSContinue height reqKey idx -> (,) (Offset 0) $ \tr ->
        guard_ $ tupleCmp (<.)
          [ _tr_height tr :<> fromIntegral height
          , _tr_requestkey tr :<> val_ reqKey
          , negate (_tr_idx tr) :<> negate (fromIntegral idx)
          ]

whenArg :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenArg p a = maybe (return ()) a p
