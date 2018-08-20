module Payout where

import           Control.Monad
import qualified Data.Map            as M
import qualified Data.Text           as T
import qualified Data.Text.IO        as T
import           Foundation
import qualified Prelude             as P
import           System.Exit
import qualified System.Process      as P

import qualified Backerei.Delegation as Delegation
import qualified Backerei.RPC        as RPC
import qualified Backerei.Types      as RPC

import           Config
import           DB

payout :: Config -> Bool -> IO ()
payout (Config baker host port from fee databasePath clientPath startingCycle cycleLength snapshotInterval _) noDryRun = do
  let conf = RPC.Config host port

      maybeUpdateEstimatesForCycle cycle db = do
        let payouts = dbPayoutsByCycle db
        if M.member cycle payouts then return (db, False) else do
          T.putStrLn $ T.concat ["Updating DB with estimates for cycle ", T.pack $ P.show cycle, "..."]
          estimatedRewards <- Delegation.estimatedRewards conf cycleLength snapshotInterval cycle baker
          ((bakerBondReward, bakerFeeReward, bakerLooseReward, bakerTotalReward), calculated, stakingBalance) <- Delegation.calculateRewardsFor conf cycleLength snapshotInterval cycle baker estimatedRewards fee
          let bakerRewards = BakerRewards bakerBondReward bakerFeeReward bakerLooseReward bakerTotalReward
              delegators = M.fromList $ fmap (\(addr, balance, payout) -> (addr, DelegatorPayout balance payout Nothing Nothing)) calculated
              cyclePayout = CyclePayout stakingBalance fee estimatedRewards bakerRewards [] Nothing Nothing delegators
          return (db { dbPayoutsByCycle = M.insert cycle cyclePayout payouts }, True)
      maybeUpdateEstimates db = do
        currentLevel <- RPC.currentLevel conf RPC.head
        let currentCycle = RPC.levelCycle currentLevel
            knownCycle   = currentCycle + 5
        foldFirst db (fmap maybeUpdateEstimatesForCycle [startingCycle .. knownCycle])

      maybeUpdateActualForCycle cycle db = do
        let payouts = dbPayoutsByCycle db
        case M.lookup cycle payouts of
          Nothing -> error "should not happen: missed lookup"
          Just cyclePayout -> do
            if isJust (cycleFinalTotalRewards cyclePayout) then do
              return (db, False)
            else do
              T.putStrLn $ T.concat ["Updating DB with actual earnings for cycle ", T.pack $ P.show cycle, "..."]
              stolen <- Delegation.stolenBlocks conf cycleLength snapshotInterval cycle baker
              let stolenBlocks = fmap (\(a, b, c, d, e) -> StolenBlock a b c d e) stolen
              hash <- Delegation.hashToQuery conf cycle cycleLength
              frozenBalanceByCycle <- RPC.frozenBalanceByCycle conf hash baker
              let [thisCycle] = P.filter ((==) cycle . RPC.frozenCycle) frozenBalanceByCycle
                  feeRewards = RPC.frozenFees thisCycle
                  extraRewards = feeRewards
                  realizedRewards = feeRewards P.+ RPC.frozenRewards thisCycle
                  estimatedRewards = cycleEstimatedTotalRewards cyclePayout
                  paidRewards = estimatedRewards P.+ extraRewards
                  realizedDifference = realizedRewards P.- paidRewards
                  estimatedDifference = estimatedRewards P.- paidRewards
                  finalTotalRewards = CycleRewards realizedRewards paidRewards realizedDifference estimatedDifference
              if estimatedDifference > 0 then fail "should not happen: positive difference" else return ()
              ((bakerBondReward, bakerFeeReward, bakerLooseReward, bakerTotalReward), calculated, _) <- Delegation.calculateRewardsFor conf cycle cycleLength snapshotInterval baker paidRewards fee
              let bakerRewards = BakerRewards bakerBondReward bakerFeeReward bakerLooseReward bakerTotalReward
                  estimatedDelegators = cycleDelegators cyclePayout
                  delegators = M.fromList $ fmap (\(addr, balance, payout) -> (addr, DelegatorPayout balance (delegatorEstimatedRewards $ estimatedDelegators M.! addr) (Just payout) Nothing)) calculated
              return (db { dbPayoutsByCycle = M.insert cycle (cyclePayout { cycleStolenBlocks = stolenBlocks, cycleFinalTotalRewards = Just finalTotalRewards,
                cycleFinalBakerRewards = Just bakerRewards, cycleDelegators = delegators }) payouts }, True)
      maybeUpdateActual db = do
        currentLevel <- RPC.currentLevel conf RPC.head
        let currentCycle = RPC.levelCycle currentLevel
            knownCycle   = currentCycle - 1
        foldFirst db (fmap maybeUpdateActualForCycle [startingCycle .. knownCycle])

      maybePayoutDelegatorForCycle cycle (address, delegator) db = do
        case delegatorPayoutOperationHash delegator of
          Just _  -> return (db, False)
          Nothing -> do
            let Just amount = delegatorFinalRewards delegator
            T.putStrLn $ T.concat ["For cycle ", T.pack $ P.show cycle, " delegator ", address, " should be paid ", T.pack $ P.show amount, " XTZ"]
            updatedDelegator <-
              if noDryRun then do
                let cmd = [clientPath, "transfer", T.pack $ P.show amount, "from", from, "to", address, "--fee", "0.0", "-q", "-w", "none"]
                T.putStrLn $ T.concat ["Running '", T.intercalate " " cmd, "'"]
                let proc = P.proc (T.unpack clientPath) $ drop 1 $ fmap T.unpack cmd
                (code, stdout, stderr) <- P.readCreateProcessWithExitCode proc ""
                if code /= ExitSuccess then do
                  T.putStrLn $ T.concat ["Failure: ", T.pack $ P.show (code, stdout, stderr)]
                else do
                  T.putStrLn $ T.pack stdout
                return delegator
              else return delegator
            return (db { dbPayoutsByCycle = M.adjust (\c -> c { cycleDelegators = M.insert address updatedDelegator $ cycleDelegators c }) cycle $ dbPayoutsByCycle db }, True)
      maybePayoutForCycle cycle db = do
        let payouts = dbPayoutsByCycle db
        case M.lookup cycle payouts of
          Nothing -> error "should not happen: missed lookup"
          Just cyclePayout -> do
            let delegators = cycleDelegators cyclePayout
            foldFirst db (fmap (maybePayoutDelegatorForCycle cycle) (M.toList delegators))
      maybePayout db = do
        currentLevel <- RPC.currentLevel conf RPC.head
        let currentCycle  = RPC.levelCycle currentLevel
            unlockedCycle = currentCycle - 6
        foldFirst db (fmap maybePayoutForCycle [startingCycle .. unlockedCycle])

      step databasePath db = do
        case db of
          Nothing -> do
            T.putStrLn $ T.concat ["Creating new DB in file ", databasePath, "..."]
            return (DB M.empty, True)
          Just prev -> do
            foldFirst prev [maybeUpdateEstimates, maybeUpdateActual, maybePayout]
      loop = do
        updated <- withDB (T.unpack databasePath) (step databasePath)
        unless (not updated) loop

  loop

foldFirst :: a -> [a -> IO (a, Bool)] -> IO (a, Bool)
foldFirst obj [] = return (obj, False)
foldFirst obj (act:rest) = do
  (new, updated) <- act obj
  if updated then return (new, updated) else foldFirst obj rest
