{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
-- |

module ChainwebDb.Queries where

------------------------------------------------------------------------------
import           Data.Aeson hiding (Error)
import           Data.ByteString.Lazy (ByteString)
import           Data.Int
import           Data.Text (Text)
import           Data.Time
import           Database.Beam hiding (insert)
import           Database.Beam.Postgres
import           Database.Beam.Postgres.Syntax
import           Database.Beam.Backend.SQL.SQL92
import           Database.Beam.Backend.SQL
------------------------------------------------------------------------------
import           ChainwebData.Api
import           ChainwebDb.Database
import           ChainwebData.Pagination
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Event
import           ChainwebDb.Types.Transaction
------------------------------------------------------------------------------

searchTxsQueryStmt
  :: Maybe Limit
  -> Maybe Offset
  -> Text
  -> SqlSelect
        Postgres
        (QExprToIdentity
                (QGenExpr QValueContext Postgres QBaseScope Int64,
                QGenExpr QValueContext Postgres QBaseScope Int64,
                QGenExpr QValueContext Postgres QBaseScope (DbHash BlockHash),
                QGenExpr QValueContext Postgres QBaseScope UTCTime,
                QGenExpr QValueContext Postgres QBaseScope (DbHash TxHash),
                QGenExpr QValueContext Postgres QBaseScope Text,
                (QGenExpr QValueContext Postgres QBaseScope (Maybe Text),
                QGenExpr QValueContext Postgres QBaseScope (Maybe (PgJSONB Value)),
                QGenExpr
                QValueContext Postgres QBaseScope (Maybe (PgJSONB Value)))))
searchTxsQueryStmt limit offset search =
    select $ do
        limit_ lim $ offset_ off $ orderBy_ (desc_ . getHeight) $ do
                tx <- all_ (_cddb_transactions database)
                guard_ (fromMaybe_ (val_ "") (_tx_code tx) `like_` (val_ searchString))
                return
                        ( (_tx_chainId tx)
                        , (_tx_height tx)
                        , (unBlockId $ _tx_block tx)
                        , (_tx_creationTime tx)
                        , (_tx_requestKey tx)
                        , (_tx_sender tx)
                        , ((_tx_code tx)
                        , (_tx_continuation tx)
                        , (_tx_goodResult tx)
                        ))
  where
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getHeight (_,a,_,_,_,_,_) = a
    searchString = "%" <> search <> "%"

eventsQueryStmt :: Maybe Limit
                -> Maybe Offset
                -> Maybe Text
                -> Maybe EventParam
                -> Maybe EventName
                -> Maybe EventModuleName
                -> Maybe Int -- BlockHeight
                -> SqlSelect
                   Postgres
                   (QExprToIdentity
                    (BlockT (QGenExpr QValueContext Postgres QBaseScope)
                    , EventT (QGenExpr QValueContext Postgres QBaseScope)))
eventsQueryStmt limit offset qSearch qParam qName qModuleName bh =
  select $
    limit_ lim $ offset_ off $ orderBy_ getOrder $ do
      blk <- all_ (_cddb_blocks database)
      ev <- all_ (_cddb_events database)
      guard_ (_ev_block ev `references_` blk)
      whenArg qSearch $ \s -> guard_
        ((_ev_qualName ev `like_` val_ (searchString s)) ||.
         (_ev_paramText ev `like_` val_ (searchString s))
        )
      whenArg qName $ \(EventName n) -> guard_ (_ev_qualName ev `like_` val_ (searchString n))
      whenArg qParam $ \(EventParam p) -> guard_ (_ev_paramText ev `like_` val_ (searchString p))
      whenArg qModuleName $ \(EventModuleName m) -> guard_ (_ev_module ev ==. val_ m)
      whenArg bh $ \bh' -> guard_ (_ev_height ev >=. val_ (fromIntegral bh'))
      return (blk,ev)
  where
    whenArg p a = maybe (return ()) a p
    lim = maybe 10 (min 100 . unLimit) limit
    off = maybe 0 unOffset offset
    getOrder (_,ev) =
      (desc_ $ _ev_height ev
      ,asc_ $ _ev_chainid ev
      ,asc_ $ _ev_idx ev)
    searchString search = "%" <> search <> "%"

_bytequery :: Sql92SelectSyntax (BeamSqlBackendSyntax be) ~ PgSelectSyntax => SqlSelect be a -> ByteString
_bytequery = \case
  SqlSelect s -> pgRenderSyntaxScript $ fromPgSelect s

txQueryStmt
  :: Text
  -> SqlSelect Postgres (QExprToIdentity (TransactionT (QExpr Postgres QBaseScope), BlockT (QExpr Postgres QBaseScope)))
txQueryStmt rk = select $ do
      tx <- all_ (_cddb_transactions database)
      blk <- all_ (_cddb_blocks database)
      guard_ (_tx_block tx `references_` blk)
      guard_ (_tx_requestKey tx ==. val_ (DbHash rk))
      return (tx,blk)

eventsOnRequestKeyStmt
  :: Text
  -> SqlSelect Postgres (QExprToIdentity (EventT (QExpr Postgres QBaseScope)))
eventsOnRequestKeyStmt rk = select $ do
    ev <- all_ (_cddb_events database)
    guard_ (_ev_requestkey ev ==. val_ (RKCB_RequestKey $ DbHash rk))
    return ev
