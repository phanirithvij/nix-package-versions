{- This module takes care of populating the database
-}

{-# LANGUAGE BangPatterns #-}
module App.Update
  ( updateDatabase
  , frequencyDays
  , Frequency
  ) where

import Control.Concurrent.MVar
import Control.Concurrent (threadDelay)
import Control.Monad (void, when, forM_)
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TVar
  (newTVarIO, newTVar, readTVar, writeTVar, TVar)
import Control.Monad.STM.Class (retry)
import Data.Foldable (traverse_)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (posixDayLength)
import Prettyprinter (Pretty(..), (<+>))

import App.Logger (Logger, withLogger, logInfo, logTimed)
import App.Storage (Database, CommitState(..))
import qualified App.Storage as Storage
import Control.Concurrent.Extra (stream)
import Data.Git (Commit(..))
import Data.Time.Period (Period(..))
import GitHub (AuthenticatingUser(..))
import qualified GitHub
import Nix
  ( Channel(..)
  , nixpkgsRepo
  , channelBranch)
import qualified Nix

data State = State
  { s_commits :: TVar (Map Commit (TVar CommitState))
  }

getOrCreateStateFor :: State -> Commit -> IO (TVar CommitState, Bool)
getOrCreateStateFor State{..} commit =
  atomically $ do
    commits <- readTVar s_commits
    case Map.lookup commit commits of
      Just var -> return (var, False)
      Nothing -> do
        var <- newTVar Incomplete
        writeTVar s_commits $ Map.insert commit var commits
        return (var, True)

-- | Blocks until the state is available
getStateFor :: State -> Commit -> IO (TVar CommitState)
getStateFor State{..} commit = do
  atomically $ do
    commits <- readTVar s_commits
    case Map.lookup commit commits of
      Nothing -> retry
      Just var -> return var

process :: Logger -> Database -> State -> Commit -> IO (TVar CommitState)
process logger db state commit = do
  (var, created) <- getOrCreateStateFor state commit
  when created $ do
    logInfo logger $ pretty commit <+> "Nix: loading packages"
    epackages <- logTimed logger (pretty commit <+> "Nix finished") $
      Nix.packagesAt commit
    finalState <- save epackages
    atomically $ writeTVar var finalState
  return var
  where
    save = \case
      Right packages -> do
        logInfo logger $ pretty commit <+> "Writing"
        logTimed logger (pretty commit <+> "Writing finished" ) $ do
          Storage.writeCommitState db commit Incomplete
          traverse_ (Storage.writePackage db commit) packages
          Storage.writeCommitState db commit Success
          return Success
      Left err -> do
        logInfo logger $ pretty commit <+> "Nix: failed" <> pretty (show err)
        Storage.writeCommitState db commit Broken
        return Broken

-- Download package information from Nix and save it to the database
-- handling at most `concurrency` parallel commits at once.
--
-- No commit is handled twice. The second time will just point to the
-- result of the first time it was attempted.
parallelWriter
  :: Logger
  -> Database
  -> Int
  -- ^ max parallelism
  -> ((Commit -> IO Bool) -> IO a)
    -- ^ save data about a commit to the db
  -> IO a
parallelWriter logger db concurrency f = do
  var <- newTVarIO mempty
  let state = State var
      -- run at most `concurrency` of these in parallel.
      -- only blocks if the Commit hasn't been handled before.
      consume commit = void $ process logger db state commit
      produce enqueue = f $ \commit -> do
        () <- enqueue commit
        cvar <- getStateFor state commit
        atomically $ do
          cstate <- readTVar cvar
          if not (isFinal cstate)
            then retry
            else return $ cstate == Success
  stream concurrency produce consume

newtype Frequency = Frequency NominalDiffTime
  deriving (Show, Eq, Ord)
  deriving newtype (Num, Real)

frequencyDays :: Int -> Frequency
frequencyDays n = Frequency $ fromIntegral n * posixDayLength

-- | Download lists of packages and their versions for commits
-- between 'to' and 'from' dates and save them to the database.
updateDatabase
  :: Database
  -> Frequency
  -> AuthenticatingUser
  -> Period
  -> IO [Either String String]
updateDatabase database freq user targetPeriod =
  withLogger $ \logger -> do
  let channels = reverse [minBound..]
  coverages <- zip channels <$> traverse (Storage.coverage database) channels
  let completed :: Map Commit CommitState
      completed = foldr add mempty $ concatMap snd coverages
        where
        add (_, commit, state) acc = Map.insert commit state acc

      wanted :: [Period]
      wanted =
        [ Period from (from + realToFrac freq)
        | from <- [start, start + realToFrac freq .. end ]
        ]
        where Period start end = targetPeriod

      missing :: [(Channel, Period)]
      missing =
        [ (channel, period)
        | channel <- channels
        , Just covered <- [lookup channel coverages]
        , period <- wanted
        -- we consider an expanded period such that if there is coverage
        -- withnin this time, then the period can be considered covered.
        , not $ any (within $ expanded period) covered
        ]
        where
          expanded (Period s e) = Period (s - halfFreq) (e + halfFreq)
            where halfFreq = realToFrac freq / 2

          within (Period s e) (Period s' e',_,state) =
            s <= s' && e' <= e && isFinal state

  let capabilities = 3 -- My ram is not enough for 8 nix-env
  logInfo logger $ "concurrency: " <> pretty capabilities
  parallelWriter logger database capabilities $ \save -> do
    results <- newMVar mempty
    let handled :: Commit -> Bool
        handled commit =
          maybe False isFinal $
          Map.lookup commit completed

        total = length missing

        processPeriod :: (Int, (Channel, Period)) -> IO ()
        processPeriod (ix, (channel, period)) = do
          logInfo logger $ "progress: " <> pretty ix <> "/" <> pretty total
          commits <- commitsWithin logger channel period
          let maxAttempts = 10
              pending = take maxAttempts $ filter (not . handled) commits
              handle commit = do
                success <- save commit
                if success
                  then do
                    Storage.writeCoverage database period channel commit
                    return $ Just commit
                  else
                   return Nothing
          mcommit <- tryInSequence $ map handle pending
          let !outcome = case mcommit of
                Just commit ->
                  Right $ unwords
                    [ "Success:"
                    , show channel
                    , show $ pretty period
                    , show $ pretty commit]
                Nothing ->
                  Left $ unwords
                    ["Failure:"
                    , show channel
                    , show $ pretty period]
          logInfo logger $ pretty $ either id id outcome
          modifyMVar_ results (return . (outcome:))

    let maxConcurrentRequests = 10
    stream maxConcurrentRequests (forM_ $ zip [0..] missing) processPeriod
    readMVar results
  where
  commitsWithin :: Logger -> Channel -> Period -> IO [Commit]
  commitsWithin logger channel period@(Period _ end) = go 0
    where
    target = "["<> pretty channel <+> pretty period <> "]"
    go :: Int -> IO [Commit]
    go retryN = do
      when (retryN > 0) $
        logInfo logger $ "GitHub: retry " <> pretty retryN <+> target
      r <- GitHub.commitsUntil user 30 nixpkgsRepo (channelBranch channel) end
      case r of
        Right commits ->
          return commits

        Left (GitHub.Retry wait) -> do
          let seconds = ceiling wait
              microseconds = 1000 * 1000 * seconds
          logInfo logger $
            "GitHub: rate limit exceeded. waiting " <>
            pretty seconds <> " seconds" <+> target
          threadDelay microseconds
          go (retryN + 1)

        Left err -> do
          logInfo logger $ "GitHub: failed" <+> target <> ": " <> pretty err
          return []


-- stops on first True
tryInSequence :: [IO (Maybe a)] -> IO (Maybe a)
tryInSequence [] = return Nothing
tryInSequence (x:xs) = x >>= \case
  Just v -> return (Just v)
  Nothing -> tryInSequence xs

isFinal :: CommitState -> Bool
isFinal = \case
  Success    -> True
  Broken     -> True
  Incomplete -> False

