{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.Agent.Socket.DS.Core where

import System.IO
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Lens
import Control.Monad.Reader
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Control.Monad.Except
import qualified Control.Exception.Safe as E
import System.Exit
import Data.Aeson
import qualified Data.ByteString as BS

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM
import qualified PMS.Domain.Model.DS.Utility as DM

import PMS.Infra.Agent.Socket.DM.Type
import PMS.Infra.Agent.Socket.DM.Constant
import PMS.Infra.Agent.Socket.DS.Utility


-- |
--
app :: AppContext ()
app = do
  $logDebugS DM._LOGTAG "app called."
  runConduit pipeline
  where
    pipeline :: ConduitM () Void AppContext ()
    pipeline = src .| cmd2task .| sink

---------------------------------------------------------------------------------
-- |
--
src :: ConduitT () DM.AgentSocketCommand AppContext ()
src = lift go >>= yield >> src
  where
    go :: AppContext DM.AgentSocketCommand
    go = do
      queue <- view DM.agentSocketQueueDomainData <$> lift ask
      liftIO $ STM.atomically $ STM.readTQueue queue

---------------------------------------------------------------------------------
-- |
--
cmd2task :: ConduitT DM.AgentSocketCommand (IOTask ()) AppContext ()
cmd2task = await >>= \case
  Just cmd -> flip catchError (errHdl cmd) $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: DM.AgentSocketCommand -> String -> ConduitT DM.AgentSocketCommand (IOTask ()) AppContext ()
    errHdl socketCmd msg = do
      let jsonrpc = DM.getJsonRpcAgentSocketCommand socketCmd
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      lift $ errorToolsCallResponse jsonrpc $ "cmd2task: exception occurred. skip. " ++ msg
      cmd2task

    go :: DM.AgentSocketCommand -> AppContext (IOTask ())
    go (DM.AgentSocketEchoCommand      dat) = genEchoTask dat
    go (DM.AgentSocketOpenCommand      dat) = genSocketOpenTask dat      -- CR-04
    go (DM.AgentSocketCloseCommand     dat) = genSocketCloseTask dat     -- CR-05
    go (DM.AgentSocketReadCommand      dat) = genSocketReadTask dat      -- CR-06
    go (DM.AgentSocketReadByteCommand  dat) = genSocketReadByteTask dat  -- CR-06
    go (DM.AgentSocketWriteCommand     dat) = genSocketWriteTask dat     -- CR-07
    go (DM.AgentSocketWriteByteCommand dat) = genSocketWriteByteTask dat -- CR-07

---------------------------------------------------------------------------------
-- |
--
sink :: ConduitT (IOTask ()) Void AppContext ()
sink = await >>= \case
  Just req -> flip catchError errHdl $ do
    lift (go req) >> sink
  Nothing -> do
    $logWarnS DM._LOGTAG "sink: await returns nothing. skip."
    sink

  where
    errHdl :: String -> ConduitT (IOTask ()) Void AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "sink: exception occurred. skip. " ++ msg
      sink

    go :: (IO ()) -> AppContext ()
    go task = do
      $logDebugS DM._LOGTAG "sink: start async."
      _ <- liftIOE $ async task
      $logDebugS DM._LOGTAG "sink: end async."
      return ()

---------------------------------------------------------------------------------
-- |
--
genEchoTask :: DM.AgentSocketEchoCommandData -> AppContext (IOTask ())
genEchoTask dat = do
  resQ <- view DM.responseQueueDomainData <$> lift ask
  let val = dat^.DM.valueAgentSocketEchoCommandData
  $logDebugS DM._LOGTAG $ T.pack $ "genEchoTask: echo : " ++ val
  return $ echoTask resQ dat val

-- |
--
echoTask :: STM.TQueue DM.McpResponse -> DM.AgentSocketEchoCommandData -> String -> IOTask ()
echoTask resQ cmdDat val = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.echoTask run. " ++ val
  DM.toolsCallResponse resQ (cmdDat^.DM.jsonrpcAgentSocketEchoCommandData) ExitSuccess val ""
  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.echoTask end."
  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = DM.toolsCallResponse resQ (cmdDat^.DM.jsonrpcAgentSocketEchoCommandData) (ExitFailure 1) "" (show e)

---------------------------------------------------------------------------------
-- | CR-04 / CR-12: agent-socket-open implementation with sandboxNetworks check.
-- The sandboxNetworks check is performed here in the gen function (AppContext),
-- consistent with how genProcRunTask performs the allowedCmds check.
-- Unix Domain Socket connections bypass the sandboxNetworks check.
genSocketOpenTask :: DM.AgentSocketOpenCommandData -> AppContext (IOTask ())
genSocketOpenTask cmdDat = do
  let argsBS = DM.unRawJsonByteString $ cmdDat^.DM.argumentsAgentSocketOpenCommandData
  resQ            <- view DM.responseQueueDomainData <$> lift ask
  handleTMVar     <- view handleAppData <$> ask
  sandboxNetworks <- view DM.sandboxNetworksDomainData <$> lift ask
  argsDat         <- liftEither $ eitherDecode argsBS
  let mFile = argsDat^.fileSocketOpenToolParams
      mHost = argsDat^.hostSocketOpenToolParams
      mPort = argsDat^.portSocketOpenToolParams
  -- CR-12: sandboxNetworks check for TCP connections only; Unix Domain Socket is exempt
  case (mFile, mHost) of
    (Nothing, Just host) -> liftIO (DM.checkSandboxNetworks sandboxNetworks host) >>= liftEither
    _                    -> return ()
  return $ socketOpenTask cmdDat resQ handleTMVar mFile mHost mPort

-- | Unix Domain Socket connection.
socketOpenTask :: DM.AgentSocketOpenCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe Handle)
               -> Maybe String
               -> Maybe String
               -> Maybe String
               -> IOTask ()
socketOpenTask cmdDat resQ handleTMVar (Just path) _ _ = flip E.catchAny errHdl $ do
  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketOpenTask (unix) start."
  STM.atomically (STM.takeTMVar handleTMVar) >>= \case
    Just h -> do
      STM.atomically $ STM.putTMVar handleTMVar (Just h)
      hPutStrLn stderr "[ERROR] socketOpenTask: socket is already connected."
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is already connected."
    Nothing -> flip E.catchAny connErrHdl $ do
      hdl <- createUnixSocketHandle path
      STM.atomically $ STM.putTMVar handleTMVar (Just hdl)
      DM.toolsCallResponse resQ jsonRpc ExitSuccess ("socket connected to unix://" ++ path) ""
  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketOpenTask (unix) end."
  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketOpenCommandData
    errHdl :: E.SomeException -> IO ()
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)
    connErrHdl :: E.SomeException -> IO ()
    connErrHdl e = do
      STM.atomically $ STM.putTMVar handleTMVar Nothing
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

-- | TCP connection. sandboxNetworks check is already done in genSocketOpenTask.
socketOpenTask cmdDat resQ handleTMVar Nothing (Just host) (Just port) = flip E.catchAny errHdl $ do
  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketOpenTask (tcp) start."
  STM.atomically (STM.takeTMVar handleTMVar) >>= \case
    Just h -> do
      STM.atomically $ STM.putTMVar handleTMVar (Just h)
      hPutStrLn stderr "[ERROR] socketOpenTask: socket is already connected."
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is already connected."
    Nothing -> flip E.catchAny connErrHdl $ do
      hdl <- createSocketHandle host port
      STM.atomically $ STM.putTMVar handleTMVar (Just hdl)
      DM.toolsCallResponse resQ jsonRpc ExitSuccess ("socket connected to " ++ host ++ ":" ++ port) ""
  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketOpenTask (tcp) end."
  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketOpenCommandData
    errHdl :: E.SomeException -> IO ()
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)
    connErrHdl :: E.SomeException -> IO ()
    connErrHdl e = do
      STM.atomically $ STM.putTMVar handleTMVar Nothing
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

-- | Invalid arguments (all other patterns).
socketOpenTask cmdDat resQ _ _ _ _ = do
  hPutStrLn stderr "[ERROR] PMS.Infra.Agent.Socket.DS.Core.socketOpenTask: invalid arguments."
  DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "invalid arguments: specify file, or host and port."
  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketOpenCommandData

---------------------------------------------------------------------------------
-- |
--
genSocketCloseTask :: DM.AgentSocketCloseCommandData -> AppContext (IOTask ())
genSocketCloseTask dat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genSocketCloseTask called. "
  handleTMVar <- view handleAppData <$> ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  return $ socketCloseTask dat resQ handleTMVar

-- |
--
socketCloseTask :: DM.AgentSocketCloseCommandData
                -> STM.TQueue DM.McpResponse
                -> STM.TMVar (Maybe Handle)
                -> IOTask ()
socketCloseTask cmdDat resQ handleTMVar = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketCloseTask run. "
  let jsonRpc = cmdDat^.DM.jsonrpcAgentSocketCloseCommandData

  STM.atomically (STM.swapTMVar handleTMVar Nothing) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Agent.Socket.DS.Core.socketCloseTask: socket is not connected."
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not connected."
    Just hdl -> do
      hClose hdl
      DM.toolsCallResponse resQ jsonRpc ExitSuccess "" "socket is closed."
      hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketCloseTask closeSocket."

  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketCloseTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = DM.toolsCallResponse resQ (cmdDat^.DM.jsonrpcAgentSocketCloseCommandData) (ExitFailure 1) "" (show e)

-- |
--
genSocketReadTask :: DM.AgentSocketReadCommandData -> AppContext (IOTask ())
genSocketReadTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsAgentSocketReadCommandData
  resQ        <- view DM.responseQueueDomainData <$> lift ask
  handleTMVar <- view handleAppData <$> ask
  argsDat     <- liftEither $ eitherDecode argsBS
  let size       = argsDat^.lengthSocketReadToolParams
      actualSize = min size _READ_BUFFER_SIZE
  return $ socketReadTask cmdData resQ handleTMVar actualSize

-- |
--
socketReadTask :: DM.AgentSocketReadCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe Handle)
               -> Int
               -> IOTask ()
socketReadTask cmdDat resQ handleTMVar size = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketReadTask run. " ++ show size

  STM.atomically (STM.readTMVar handleTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Agent.Socket.DS.Core.socketReadTask: socket is not connected."
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not connected."
    Just hdl -> do
      output <- DM.readHandle hdl _SOCKET_READ_WAIT_MSEC size
      DM.toolsCallResponse resQ jsonRpc ExitSuccess (DM.bs2strUTF8 output) ""

  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketReadTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketReadCommandData
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

-- |
--
genSocketReadByteTask :: DM.AgentSocketReadByteCommandData -> AppContext (IOTask ())
genSocketReadByteTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsAgentSocketReadByteCommandData
  resQ        <- view DM.responseQueueDomainData <$> lift ask
  handleTMVar <- view handleAppData <$> ask
  argsDat     <- liftEither $ eitherDecode argsBS
  let size       = argsDat^.lengthSocketReadByteToolParams
      actualSize = min size _READ_BUFFER_SIZE
  return $ socketReadByteTask cmdData resQ handleTMVar actualSize

-- |
--
socketReadByteTask :: DM.AgentSocketReadByteCommandData
                   -> STM.TQueue DM.McpResponse
                   -> STM.TMVar (Maybe Handle)
                   -> Int
                   -> IOTask ()
socketReadByteTask cmdDat resQ handleTMVar size = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketReadByteTask run. " ++ show size

  STM.atomically (STM.readTMVar handleTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Agent.Socket.DS.Core.socketReadByteTask: socket is not connected."
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not connected."
    Just hdl -> do
      output <- DM.readHandle hdl _SOCKET_READ_WAIT_MSEC size
      DM.toolsCallResponse resQ jsonRpc ExitSuccess (DM.bytesToHex output) ""

  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketReadByteTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketReadByteCommandData
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

-- |
--
_SOCKET_READ_WAIT_MSEC :: Int
_SOCKET_READ_WAIT_MSEC = 100

---------------------------------------------------------------------------------
-- | CR-07 / CR-12: agent-socket-write implementation with invalidPatterns check.
-- The invalidPatterns check is performed here in the gen function (AppContext),
-- consistent with how genProcRunTask performs the allowedCmds check.
genSocketWriteTask :: DM.AgentSocketWriteCommandData -> AppContext (IOTask ())
genSocketWriteTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsAgentSocketWriteCommandData
  resQ            <- view DM.responseQueueDomainData <$> lift ask
  handleTMVar     <- view handleAppData <$> ask
  invalidPatterns <- view DM.invalidPatternsDomainData <$> lift ask
  argsDat         <- liftEither $ eitherDecode argsBS
  let str           = argsDat^.dataSocketWriteToolParams
      appendNewline = argsDat^.appendNewlineSocketWriteToolParams
  -- CR-12: invalidPatterns check (pure check, consistent with eitherDecode validation)
  case DM.checkInvalidPatterns invalidPatterns str of
    Just pat -> throwError $
      "agent-socket-write: rejected. input matches invalidPatterns: " ++ show pat
    Nothing  -> return ()
  return $ socketWriteTask cmdData resQ handleTMVar str appendNewline

-- |
--
socketWriteTask :: DM.AgentSocketWriteCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe Handle)
               -> String
               -> Maybe Bool
               -> IOTask ()
socketWriteTask cmdDat resQ handleTMVar str appendNewline = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketWriteTask run."

  STM.atomically (STM.readTMVar handleTMVar) >>= \case
    Nothing ->
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not connected."
    Just hdl -> do
      -- Apply appendCRLF (auto-append newline) unless appendNewline is explicitly False.
      let payload = if appendNewline == Just False
                      then str
                      else DM.appendCRLF str
          bs = TE.encodeUtf8 (T.pack payload)
      hPutStrLn stderr $ "PMS.Infra.Agent.Socket.DS.Core.socketWriteTask " ++ show bs
      DM.writeHandle hdl bs
      DM.toolsCallResponse resQ jsonRpc ExitSuccess "" ""

  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketWriteTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketWriteCommandData
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

---------------------------------------------------------------------------------
-- | CR-07: agent-socket-write-byte implementation
--
genSocketWriteByteTask :: DM.AgentSocketWriteByteCommandData -> AppContext (IOTask ())
genSocketWriteByteTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsAgentSocketWriteByteCommandData
  resQ        <- view DM.responseQueueDomainData <$> lift ask
  handleTMVar <- view handleAppData <$> ask
  argsDat     <- liftEither $ eitherDecode argsBS
  let hex = argsDat^.dataSocketWriteByteToolParams
  bs          <- liftEither $ hexToBytes hex
  return $ socketWriteByteTask cmdData resQ handleTMVar bs

-- |
--
socketWriteByteTask :: DM.AgentSocketWriteByteCommandData
                   -> STM.TQueue DM.McpResponse
                   -> STM.TMVar (Maybe Handle)
                   -> BS.ByteString
                   -> IOTask ()
socketWriteByteTask cmdDat resQ handleTMVar bs = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketWriteByteTask run."

  STM.atomically (STM.readTMVar handleTMVar) >>= \case
    Nothing ->
      DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not connected."
    Just hdl -> do
      hPutStrLn stderr $ "PMS.Infra.Agent.Socket.DS.Core.socketWriteByteTask " ++ show bs
      DM.writeHandle hdl bs
      DM.toolsCallResponse resQ jsonRpc ExitSuccess "" ""

  hPutStrLn stderr "[INFO] PMS.Infra.Agent.Socket.DS.Core.socketWriteByteTask end."

  where
    jsonRpc = cmdDat^.DM.jsonrpcAgentSocketWriteByteCommandData
    errHdl e = DM.toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)
