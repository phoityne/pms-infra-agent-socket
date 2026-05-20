{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.Agent.Socket.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH
import System.IO
import qualified Control.Concurrent.STM as STM

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.TH as DM

-- |
--
data AppData = AppData {
               _handleAppData :: STM.TMVar (Maybe Handle)
             , _lockAppData   :: STM.TMVar ()
             }

makeLenses ''AppData

defaultAppData :: IO AppData
defaultAppData = do
  mgrVar <- STM.newTMVarIO Nothing
  lock   <- STM.newTMVarIO ()
  return AppData {
           _handleAppData = mgrVar
         , _lockAppData   = lock
         }

-- |
--
type AppContext = ReaderT AppData (ReaderT DM.DomainData (ExceptT DM.ErrorData (LoggingT IO)))

-- |
--
type IOTask = IO

---------------------------------------------------------------------------------
-- | Arguments for agent-socket-open.
-- All fields are Maybe String so that the AI can omit irrelevant fields
-- depending on the connection type without causing a JSON parse error.
--
-- Routing rule (evaluated in socketOpenTask):
--   file = Just path              -> Unix Domain Socket connection
--   host = Just h, port = Just p  -> TCP connection
--   otherwise                     -> invalid arguments error
data SocketOpenToolParams =
  SocketOpenToolParams {
    _hostSocketOpenToolParams :: Maybe String
  , _portSocketOpenToolParams :: Maybe String
  , _fileSocketOpenToolParams :: Maybe String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketOpenToolParams", omitNothingFields = True} ''SocketOpenToolParams)
makeLenses ''SocketOpenToolParams

instance Default SocketOpenToolParams where
  def = SocketOpenToolParams {
        _hostSocketOpenToolParams = Nothing
      , _portSocketOpenToolParams = Nothing
      , _fileSocketOpenToolParams = Nothing
      }

---------------------------------------------------------------------------------
-- | Arguments for agent-socket-read.
data SocketReadToolParams =
  SocketReadToolParams {
    _lengthSocketReadToolParams :: Int
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketReadToolParams", omitNothingFields = True} ''SocketReadToolParams)
makeLenses ''SocketReadToolParams

instance Default SocketReadToolParams where
  def = SocketReadToolParams {
        _lengthSocketReadToolParams = 0
      }

-- | Arguments for agent-socket-read-byte.
data SocketReadByteToolParams =
  SocketReadByteToolParams {
    _lengthSocketReadByteToolParams :: Int
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketReadByteToolParams", omitNothingFields = True} ''SocketReadByteToolParams)
makeLenses ''SocketReadByteToolParams

instance Default SocketReadByteToolParams where
  def = SocketReadByteToolParams {
        _lengthSocketReadByteToolParams = 0
      }


---------------------------------------------------------------------------------
-- | Arguments for agent-socket-write.
-- appendNewline: Nothing or Just True (default) -> apply appendCRLF (auto-append newline).
--                Just False -> send string as-is without any modification.
data SocketWriteToolParams =
  SocketWriteToolParams {
    _dataSocketWriteToolParams        :: String
  , _appendNewlineSocketWriteToolParams :: Maybe Bool
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketWriteToolParams", omitNothingFields = True} ''SocketWriteToolParams)
makeLenses ''SocketWriteToolParams

instance Default SocketWriteToolParams where
  def = SocketWriteToolParams {
        _dataSocketWriteToolParams          = ""
      , _appendNewlineSocketWriteToolParams = def
      }

-- | Arguments for agent-socket-write-byte.
data SocketWriteByteToolParams =
  SocketWriteByteToolParams {
    _dataSocketWriteByteToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketWriteByteToolParams", omitNothingFields = True} ''SocketWriteByteToolParams)
makeLenses ''SocketWriteByteToolParams

instance Default SocketWriteByteToolParams where
  def = SocketWriteByteToolParams {
        _dataSocketWriteByteToolParams = ""
      }
