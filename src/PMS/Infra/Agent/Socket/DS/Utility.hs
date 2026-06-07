{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.Agent.Socket.DS.Utility where

import Control.Lens
import System.IO
import System.Log.FastLogger
import qualified Control.Exception.Safe as E
import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Network.Socket

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DS.Utility as DM
import PMS.Infra.Agent.Socket.DM.Type

-- |
--
runApp :: DM.DomainData -> AppData -> TimedFastLogger -> AppContext a -> IO (Either DM.ErrorData a)
runApp domDat appDat logger ctx =
  DM.runFastLoggerT domDat logger
    $ runExceptT
    $ flip runReaderT domDat
    $ runReaderT ctx appDat

-- |
--
liftIOE :: IO a -> AppContext a
liftIOE f = liftIO (go f) >>= liftEither
  where
    go :: IO b -> IO (Either String b)
    go x = E.catchAny (Right <$> x) errHdl

    errHdl :: E.SomeException -> IO (Either String a)
    errHdl = return . Left . show

---------------------------------------------------------------------------------
-- |
--
errorToolsCallResponse :: DM.JsonRpcRequest -> String -> AppContext ()
errorToolsCallResponse jsonRpc errStr = do
  let content = [ DM.McpToolsCallResponseResultContent "text" errStr ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = True
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  resQ <- view DM.responseQueueDomainData <$> lift ask
  liftIOE $ STM.atomically $ STM.writeTQueue resQ res

---------------------------------------------------------------------------------
-- | Convert a TCP host/port to a Handle.
-- The socket must not be used directly after socketToHandle.
createSocketHandle :: HostName -> ServiceName -> IO Handle
createSocketHandle host port = do
  sock <- createSocket host port
  hdl  <- socketToHandle sock ReadWriteMode
  hSetBuffering hdl NoBuffering
  return hdl

-- | Connect to a Unix Domain Socket path and return a Handle.
-- The socket must not be used directly after socketToHandle.
-- Supported on Windows 10 Build 17063+ and Windows 11 via AF_UNIX (network >= 3.1.3.0).
createUnixSocketHandle :: FilePath -> IO Handle
createUnixSocketHandle path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  hdl  <- socketToHandle sock ReadWriteMode
  hSetBuffering hdl NoBuffering
  return hdl

-- |
--
createSocket :: HostName -> ServiceName -> IO Socket
createSocket host port = do
  let hint  = Just defaultHints { addrSocketType = Stream }
      justH = Just host
      justP = Just port

  getAddrInfo hint justH justP >>= \case
    [] -> E.throwString "No suitable address found for the given host and port."
    (serverAddr:_) -> do
      sock <- socket (addrFamily serverAddr) (addrSocketType serverAddr) (addrProtocol serverAddr)
      connect sock (addrAddress serverAddr)
      return sock
