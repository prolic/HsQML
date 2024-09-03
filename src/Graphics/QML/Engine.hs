{-# LANGUAGE
    DeriveDataTypeable,
    FlexibleContexts,
    GeneralizedNewtypeDeriving
  #-}

-- | Functions for starting QML engines, displaying content in a window.
module Graphics.QML.Engine (
  -- * Engines
  EngineConfig(
    EngineConfig,
    initialDocument,
    contextObject,
    importPaths,
    pluginPaths,
    iconPath),
  defaultEngineConfig,
  Engine,
  runEngine,
  runEngineWith,
  runEngineAsync,
  runEngineLoop,
  joinEngine,
  killEngine,

  -- * Event Loop
  RunQML(),
  runEventLoop,
  runEventLoopNoArgs,
  requireEventLoop,
  setQtArgs,
  getQtArgs,
  QtFlag(
    QtShareOpenGLContexts),
  setQtFlag,
  getQtFlag,
  shutdownQt,
  EventLoopException(),

  -- * Document Paths
  DocumentPath(),
  fileDocument,
  uriDocument
) where

import Graphics.QML.Internal.JobQueue
import Graphics.QML.Internal.Marshal
import Graphics.QML.Internal.BindPrim
import Graphics.QML.Internal.BindCore
import Graphics.QML.Marshal ()
import Graphics.QML.Objects

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Maybe
import qualified Data.Text as T
import Data.List
import Data.Traversable (sequenceA)
import Data.Typeable
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CChar)
import Foreign.Marshal.Array
import Foreign.Ptr
import Foreign.Storable
import System.Environment (getProgName, getArgs, withProgName, withArgs)
import System.FilePath (FilePath, isAbsolute, splitDirectories, pathSeparators)

-- | Holds parameters for configuring a QML runtime engine.
data EngineConfig = EngineConfig {
  -- | Path to the first QML document to be loaded.
  initialDocument    :: DocumentPath,
  -- | Context 'Object' made available to QML script code.
  contextObject      :: Maybe AnyObjRef,
  -- | Additional search paths for QML modules
  importPaths        :: [FilePath],
  -- | Additional search paths for QML native plugins
  pluginPaths        :: [FilePath],
  iconPath           :: Maybe FilePath
}

foreign import ccall "hsqml_set_window_icon" setWindowIcon :: Ptr CChar -> IO ()


-- | Default engine configuration. Loads @\"main.qml\"@ from the current
-- working directory into a visible window with no context object.
defaultEngineConfig :: EngineConfig
defaultEngineConfig = EngineConfig {
  initialDocument    = DocumentPath "main.qml",
  contextObject      = Nothing,
  importPaths        = [],
  pluginPaths        = [],
  iconPath           = Nothing
}

-- | Represents a QML engine.
data Engine = Engine HsQMLEngineHandle (MVar ())

-- | Starts a new QML engine using the supplied configuration and returns
-- immediately without blocking.
runEngineAsync :: EngineConfig -> RunQML Engine
runEngineAsync config = RunQML $ do
    hsqmlInit
    finishVar <- newEmptyMVar

    let obj = contextObject config
        DocumentPath res = initialDocument config
        impPaths = importPaths config
        plugPaths = pluginPaths config
        stopCb = putMVar finishVar () 

    ctxHndl <- sequenceA $ fmap mToHndl obj
    engHndl <- mWithCVal (T.pack res) $ \resPtr ->
        withManyArray0 mWithCVal (map T.pack impPaths) nullPtr $ \impPtr ->
        withManyArray0 mWithCVal (map T.pack plugPaths) nullPtr $ \plugPtr ->
            hsqmlCreateEngine ctxHndl (HsQMLStringHandle $ castPtr resPtr)
                (castPtr impPtr) (castPtr plugPtr) stopCb

    case iconPath config of
        Just path -> liftIO $ withCString path setWindowIcon
        Nothing -> return ()

    return $ Engine engHndl finishVar

withMany :: (a -> (b -> m c) -> m c) -> [a] -> ([b] -> m c) -> m c
withMany func as cont =
    let rec (a:as') bs = func a (\b -> rec as' (bs . (b:)))
        rec []      bs = cont $ bs []
    in rec as id

withManyArray0 :: Storable b =>
    (a -> (b -> IO c) -> IO c) -> [a] -> b -> (Ptr b -> IO c) -> IO c
withManyArray0 func as term cont =
    withMany func as $ \ptrs -> withArray0 term ptrs cont

-- | Waits for the specified Engine to terminate.
joinEngine :: Engine -> IO ()
joinEngine (Engine _ finishVar) = void $ readMVar finishVar

-- | Kills the specified Engine asynchronously.
killEngine :: Engine -> IO ()
killEngine (Engine hndl _) = postJob $ hsqmlKillEngine hndl

-- | Starts a new QML engine using the supplied configuration. The \'with\'
-- function is executed once the engine has been started and after it returns
-- this function blocks until the engine has terminated.
runEngineWith :: EngineConfig -> (Engine -> RunQML a) -> RunQML a
runEngineWith config with = do
    eng <- runEngineAsync config
    ret <- with eng
    RunQML $ joinEngine eng
    return ret

-- | Starts a new QML engine using the supplied configuration and blocks until
-- the engine has terminated.
runEngine :: EngineConfig -> RunQML ()
runEngine config = runEngineAsync config >>= (RunQML . joinEngine)

-- | Conveniance function that both runs the event loop and starts a new QML
-- engine. It blocks keeping the event loop running until the engine has
-- terminated.
runEngineLoop :: EngineConfig -> IO ()
runEngineLoop config =
    runEventLoop $ runEngine config

-- | Wrapper around the IO monad for running actions which depend on the Qt
-- event loop.
newtype RunQML a = RunQML (IO a) deriving (Functor, Applicative, Monad)

instance MonadIO RunQML where
    liftIO = RunQML

-- | This function enters the Qt event loop and executes the supplied function
-- in the 'RunQML' monad on a new unbound thread. The event loop will continue
-- to run until all functions in the 'RunQML' monad have completed. This
-- includes both the 'RunQML' function launched by this call and any launched
-- asynchronously via 'requireEventLoop'. When the event loop exits, all
-- engines will be terminated.
--
-- It's recommended that applications run the event loop on their primordial
-- thread as some platforms mandate this. Once the event loop has finished, it
-- can be started again, but only on the same operating system thread as
-- before. If the event loop fails to start then an 'EventLoopException' will
-- be thrown.
--
-- If the event loop is entered for the first time then the currently set
-- runtime command line arguments will be passed to Qt. Hence, while calling
-- back to the supplied function, attempts to read the runtime command line
-- arguments using the System.Environment module will only return those
-- arguments not already consumed by Qt (per 'getQtArgs').
runEventLoop :: RunQML a -> IO a
runEventLoop (RunQML runFn) = do
    prog <- getProgName
    args <- getArgs
    setQtArgs prog args
    runEventLoopNoArgs . RunQML $ do
        (prog', args') <- getQtArgsIO
        withProgName prog' $ withArgs args' runFn

-- | Enters the Qt event loop in the same manner as 'runEventLoop', but does
-- not perform any processing related to command line arguments.
runEventLoopNoArgs :: RunQML a -> IO a
runEventLoopNoArgs (RunQML runFn) = tryRunInBoundThread $ do
    hsqmlInit
    finishVar <- newEmptyMVar
    let startCb = void $ forkIO $ do
            ret <- try runFn
            case ret of
                Left ex -> putMVar finishVar $ throwIO (ex :: SomeException)
                Right ret' -> putMVar finishVar $ return ret'
            hsqmlEvloopRelease
        yieldCb = if rtsSupportsBoundThreads
                  then Nothing
                  else Just yield
    status <- hsqmlEvloopRun startCb processJobs yieldCb
    case statusException status of
        Just ex -> throw ex
        Nothing -> do 
            finFn <- takeMVar finishVar
            finFn

tryRunInBoundThread :: IO a -> IO a
tryRunInBoundThread action =
    if rtsSupportsBoundThreads
    then runInBoundThread action
    else action

-- | Executes a function in the 'RunQML' monad asynchronously to the event
-- loop. Callers must apply their own sychronisation to ensure that the event
-- loop is currently running when this function is called, otherwise an
-- 'EventLoopException' will be thrown. The event loop will not exit until the
-- supplied function has completed.
requireEventLoop :: RunQML a -> IO a
requireEventLoop (RunQML runFn) = do
    hsqmlInit
    let reqFn = do
            status <- hsqmlEvloopRequire
            case statusException status of
                Just ex -> throw ex
                Nothing -> return ()
    bracket_ reqFn hsqmlEvloopRelease runFn

-- | Sets the program name and command line arguments used by Qt and returns
-- True if successful. This must be called before the first time the Qt event
-- loop is entered otherwise it will have no effect and return False. By
-- default Qt receives no arguments and the program name is set to "HsQML".
setQtArgs :: String -> [String] -> IO Bool
setQtArgs prog args = do
    hsqmlInit
    withManyArray0 mWithCVal (map T.pack (prog:args)) nullPtr
        (hsqmlSetArgs . castPtr)

-- | Gets the program name and any command line arguments remaining from an
-- earlier call to 'setQtArgs' once Qt has removed any it understands, leaving
-- only application specific arguments.
getQtArgs :: RunQML (String, [String])
getQtArgs = RunQML getQtArgsIO

getQtArgsIO :: IO (String, [String])
getQtArgsIO = do
    argc <- hsqmlGetArgsCount
    withManyArray0 mWithCVal (replicate argc $ T.pack "") nullPtr $ \argv -> do
        hsqmlGetArgs $ castPtr argv
        argvs <- peekArray0 nullPtr argv
        Just (arg0:args) <- runMaybeT $ mapM (fmap T.unpack . mFromCVal) argvs
        return (arg0, args)

-- | Represents a Qt application flag.
data QtFlag
    -- | Enables resource sharing between OpenGL contexts. This must be set in
    -- order to use QtWebEngine. 
    = QtShareOpenGLContexts
    deriving Show

internalFlag :: QtFlag -> HsQMLGlobalFlag
internalFlag QtShareOpenGLContexts = HsqmlGflagShareOpenglContexts

-- | Sets or clears one of the application flags used by Qt and returns True
-- if successful. If the flag or flag value is not supported then it will
-- return False. Setting flags once the Qt event loop is entered is
-- unsupported and will also cause this function to return False.
setQtFlag :: QtFlag -> Bool -> IO Bool
setQtFlag flag val = do
    hsqmlInit
    hsqmlSetFlag (internalFlag flag) val

-- | Gets the state of one of the application flags used by Qt.
getQtFlag :: QtFlag -> RunQML Bool
getQtFlag = RunQML . hsqmlGetFlag . internalFlag

-- | Shuts down and frees resources used by the Qt framework, preventing
-- further use of the event loop. The framework is initialised when
-- 'runEventLoop' is first called and remains initialised afterwards so that
-- the event loop can be reentered if desired (e.g. when using GHCi). Once
-- shut down, the framework cannot be reinitialised.
--
-- It is recommended that you call this function at the end of your program as
-- this library will try, but cannot guarantee in all configurations to be able
-- to shut it down for you. Failing to shutdown the framework has been known to
-- intermittently cause crashes on process exit on some platforms.
--
-- This function must be called from the event loop thread and the event loop
-- must not be running at the time otherwise an 'EventLoopException' will be
-- thrown.
shutdownQt :: IO ()
shutdownQt = do
    status <- hsqmlEvloopShutdown
    case statusException status of
        Just ex -> throw ex
        Nothing -> return ()

statusException :: HsQMLEventLoopStatus -> Maybe EventLoopException
statusException HsqmlEvloopOk = Nothing
statusException HsqmlEvloopAlreadyRunning = Just EventLoopAlreadyRunning
statusException HsqmlEvloopPostShutdown = Just EventLoopPostShutdown
statusException HsqmlEvloopWrongThread = Just EventLoopWrongThread
statusException HsqmlEvloopNotRunning = Just EventLoopNotRunning
statusException _ = Just EventLoopOtherError

-- | Exception type used to report errors pertaining to the event loop.
data EventLoopException
    = EventLoopAlreadyRunning
    | EventLoopPostShutdown
    | EventLoopWrongThread
    | EventLoopNotRunning
    | EventLoopOtherError
    deriving (Show, Typeable)

instance Exception EventLoopException

-- | Path to a QML document file.
newtype DocumentPath = DocumentPath String

-- | Converts a local file path into a 'DocumentPath'.
fileDocument :: FilePath -> DocumentPath
fileDocument fp =
    let ds = splitDirectories fp
        isAbs = isAbsolute fp
        fixHead =
            (\cs -> if null cs then [] else '/':cs) .
            takeWhile (`notElem` pathSeparators)
        mapHead _ [] = []
        mapHead f (x:xs) = f x : xs
        afp = intercalate "/" $ mapHead fixHead ds
        rfp = intercalate "/" ds
    in DocumentPath $ if isAbs then "file://" ++ afp else rfp

-- | Converts a URI string into a 'DocumentPath'.
uriDocument :: String -> DocumentPath
uriDocument = DocumentPath
