{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Backend.Builders
  ( getAllBuilders
  , getIdleBuilders
  , setBuilderStatus
  , newEmptyBuilderManager
  , startBuilders
  , startSingleBuilder
  ) where

------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Lens
import           Control.Monad
import           Data.IORef
import qualified Data.Map as M
import           Data.Time
import           Database.Beam
import           Database.Beam.Sqlite
import           Database.SQLite.Simple
------------------------------------------------------------------------------
import           Backend.Build
import           Backend.Db
import           Backend.Types.BuilderManager
import           Backend.Types.ServerEnv
import           Common.Types.Builder
import           Common.Types.Platform
import           Nix.Utils
------------------------------------------------------------------------------


getAllBuilders :: Connection -> IO [Builder]
getAllBuilders dbConn = do
  runBeamSqlite dbConn $ do
    runSelectReturningList $ select $
      all_ (_ciDb_builders ciDb)

getIdleBuilders :: Connection -> Platform -> IO [Builder]
getIdleBuilders dbConn plat = do
  runBeamSqlite dbConn $ do
    runSelectReturningList $ select $ do
      builder <- all_ (_ciDb_builders ciDb)
      guard_ ( builder ^. builder_status ==. (val_ BuilderIdle) &&.
               builder ^. builder_platform ==. (val_ plat)
             )
      return builder

setBuilderStatus :: Connection -> BuilderId -> UTCTime -> BuilderStatus -> IO ()
setBuilderStatus dbConn (BuilderId bid) t status = do
  runBeamSqlite dbConn $ do
    runUpdate $ update
      (_ciDb_builders ciDb)
      (\builder -> mconcat
           [ builder ^. builder_lastStatusUpdate <-. val_ t
           , builder ^. builder_status <-. val_ status
           ])
      (\builder -> builder ^. builder_id ==. val_ bid)
    return ()

newEmptyBuilderManager :: IO BuilderManager
newEmptyBuilderManager = BuilderManager <$> newIORef mempty

addBuildThread :: BuilderManager -> MBuilderId -> ThreadId -> IO ()
addBuildThread (BuilderManager ref) bid tid =
    atomicModifyIORef' ref (\m -> (M.insert bid tid m, ()))

startSingleBuilder :: ServerEnv -> Maybe Builder -> IO ()
startSingleBuilder se b = do
    tid <- forkIO $ buildManagerThread se b
    addBuildThread (_serverEnv_builderManager se)
      (mkeyToNullable $ fmap primaryKey b) tid

startBuilders :: ServerEnv -> IO ()
startBuilders se = do
    mplat <- getNixSystem
    case mplat of
      Nothing -> error "Could not get current value of nix system"
      Just p -> do
        -- Start up all the builder threads
        remotes <- getAllBuilders (_serverEnv_db se)
        forM_ (maybeMasterBuilder p remotes) (startSingleBuilder se)


------------------------------------------------------------------------------
-- | Eventually we may want to let the user configure whether the master node
-- also does builds.  For now, this is simpler and puts less burden on the
-- user.
maybeMasterBuilder :: Platform -> [Builder] -> [Maybe Builder]
maybeMasterBuilder p bs =
    if any ((==p) . _builder_platform) bs
      then mbs
      else Nothing : mbs
  where
    mbs = map Just bs
