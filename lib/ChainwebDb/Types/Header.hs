{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

module ChainwebDb.Types.Header where

import BasePrelude
import Database.Beam
------------------------------------------------------------------------------
import ChainwebDb.Types.DbHash
------------------------------------------------------------------------------

data HeaderT f = Header
  { _header_creationTime :: C f Int
  , _header_chainId :: C f Int
  , _header_height :: C f Int
  , _header_hash :: C f DbHash
  , _header_parent :: C f DbHash
  , _header_payloadHash :: C f DbHash
  , _header_target :: C f DbHash
  , _header_weight :: C f DbHash
  , _header_epochStart :: C f Int
  , _header_nonce :: C f Word64
  , _header_powHash :: C f DbHash }
  deriving stock (Generic)
  deriving anyclass (Beamable)

type Header = HeaderT Identity
type HeaderId = PrimaryKey HeaderT Identity

instance Table HeaderT where
  data PrimaryKey HeaderT f = HeaderId (C f DbHash)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey = HeaderId . _header_hash
