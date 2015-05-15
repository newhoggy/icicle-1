-- | Evaluate Avalanche programs
{-# LANGUAGE NoImplicitPrelude #-}
module Icicle.Avalanche.Eval (
    evalProgram
  ) where

import              Icicle.Avalanche.Program

import              Icicle.BubbleGum

import              Icicle.Common.Base
import              Icicle.Common.Value
import qualified    Icicle.Common.Exp as XV

import              Icicle.Data.DateTime
import              Icicle.Data         (AsAt(..))

import              P

import              Data.Either.Combinators
import              Data.List   (take, reverse, sort)
import qualified    Data.Map    as Map


-- | Store history information about the accumulators
type AccumulatorHeap n
 = Map.Map (Name n) ([BubbleGumFact], AccumulatorValue)

-- | The value of an accumulator
data AccumulatorValue
 -- | Whether this fold is windowed or not
 = AVFold Bool BaseValue
 -- | Accumulator storing latest N values
 -- Stored in reverse so we can just cons or take it
 | AVLatest Int [BaseValue]

 -- | A mutable value with no history attached
 | AVMutable BaseValue
 deriving (Eq, Ord, Show)


-- | What can go wrong evaluating an Avalanche
data RuntimeError n p
 = RuntimeErrorNoAccumulator (Name n)
 | RuntimeErrorPre           (XV.RuntimeError n p)
 | RuntimeErrorAccumulator   (XV.RuntimeError n p)
 | RuntimeErrorLoop          (XV.RuntimeError n p)
 | RuntimeErrorLoopAccumulatorBad (Name n)
 | RuntimeErrorIfNotBool     BaseValue
 | RuntimeErrorForeachNotInt BaseValue BaseValue
 | RuntimeErrorPost          (XV.RuntimeError n p)
 | RuntimeErrorReturn        (XV.RuntimeError n p)
 | RuntimeErrorNotBaseValue  (Value n p)
 | RuntimeErrorAccumulatorLatestNotInt  BaseValue
 deriving (Eq, Show)


-- | Extract base value; return an error if it's a closure
baseValue :: Value n p -> Either (RuntimeError n p) BaseValue
baseValue v
 = getBaseValue (RuntimeErrorNotBaseValue v) v


-- | Update value or push value to an accumulator, taking care of history
updateOrPush
        :: Ord n
        => AccumulatorHeap n
        -> Name n
        -> BubbleGumFact
        -> BaseValue
        -> Either (RuntimeError n p) (AccumulatorHeap n)

updateOrPush heap n bg v
 = do   v' <- maybeToRight (RuntimeErrorNoAccumulator n)
                           (Map.lookup n heap)
        case v' of
         (bgs, AVFold windowed _)
          -> return
           $ Map.insert n (bg : bgs, AVFold windowed v) heap
         (bgs, AVLatest num vs)
          -> return 
           $ Map.insert n
           ( take num (bg : bgs)
           , AVLatest num (take num (v : vs)) ) heap
         (_, AVMutable _)
          -> return
           $ Map.insert n ([], AVMutable v) heap


-- | For each accumulator value, write its scalar value back into the environment.
updateHeapFromAccs
        :: Ord n
        => Heap n p
        -> AccumulatorHeap n
        -> Heap n p

updateHeapFromAccs env accs
 = Map.foldWithKey upd env accs
 where
  upd n (_,v) e
   = case v of
      AVFold _ v'
       -> Map.insert n (VBase v') e
      AVLatest _ vs
       -> Map.insert n (VBase $ VArray $ reverse vs) e
      AVMutable v'
       -> Map.insert n (VBase v') e


-- | For each accumulator value, get the history information
bubbleGumOutputOfAccumulatorHeap
        :: Ord n
        => AccumulatorHeap n
        -> [BubbleGumOutput n (BaseValue)]

bubbleGumOutputOfAccumulatorHeap acc
 = concatMap  mk
 $ Map.toList acc
 where
  mk (n, (_, AVFold False v))
   = [BubbleGumReduction n v]
  mk (_, (bgs, AVFold True _))
   = [BubbleGumFacts $ sort $ fmap flav bgs]
  mk (_, (bgs, AVLatest _ _))
   = [BubbleGumFacts $ sort $ fmap flav bgs]
  mk (_, (_, AVMutable _))
   = []
  
  flav (BubbleGumFact f) = f


-- | Evaluate an entire program
-- with given primitive evaluator and values
evalProgram
        :: Ord n
        => XV.EvalPrim n p
        -> DateTime
        -> [AsAt (BubbleGumFact, BaseValue)]
        -> Program n p
        -> Either (RuntimeError n p) ([BubbleGumOutput n BaseValue], BaseValue)

evalProgram evalPrim now values p
 = do   -- Precomputations are just expressions
        pres  <- mapLeft RuntimeErrorPre
               $ XV.evalExps evalPrim
                    (Map.singleton (binddate p) $ VBase $ VDateTime $ now)
                    (precomps p)
        
        -- Initialise all the accumulators into their own heap
        accs  <- Map.fromList <$> mapM (initAcc evalPrim pres) (accums   p)

        -- Keep evaluating the same loop for every value
        -- with accumulator and scalar heaps threaded through
        accs' <- foldM (evalLoop evalPrim now (loop p) pres) accs values

        -- Push the accumulators back into scalar heap
        let env'  = updateHeapFromAccs pres accs'

        -- Grab the history out of the accumulator heap while we're at it
        let bgs = bubbleGumOutputOfAccumulatorHeap accs'

        -- Use final scalar heap to evaluate postcomputations
        posts <- mapLeft RuntimeErrorPost
                $ XV.evalExps evalPrim env' (postcomps p)

        -- Then use postcomputations to evaluate the return value
        ret   <- mapLeft RuntimeErrorReturn
                (XV.eval evalPrim posts (returns p))
             >>= baseValue

        return (bgs, ret)


-- | Initialise an accumulator
initAcc :: Ord n
        => XV.EvalPrim n p
        -> Heap n p
        -> Accumulator n p
        -> Either (RuntimeError n p) (Name n, ([BubbleGumFact], AccumulatorValue))

initAcc evalPrim env (Accumulator n at _ x)
 = do av <- getValue
      -- There is no history yet, just a value
      return (n, ([], av))
 where
  ev
   = do v <- mapLeft RuntimeErrorAccumulator
           $ XV.eval evalPrim env x
        baseValue v

  getValue
   = case at of
     -- Start with initial value.
     -- TODO: take list of previously saved resumes, and lookup here
     Resumable
      -> AVFold False <$> ev
     Windowed
      -> AVFold True <$> ev
     Mutable
      -> AVMutable <$> ev
     Latest
            -- Figure out how many latest to store,
            -- but nothing is stored yet
      -> do v    <- ev
            case v of
             VInt i
              -> return $ AVLatest i []
             _
              -> Left (RuntimeErrorAccumulatorLatestNotInt v)


-- | Evaluate an entire loop for a single value
-- Takes accumulator and scalar heaps and value, returns new heaps.
evalLoop
        :: Ord n
        => XV.EvalPrim n p
        -> DateTime
        -> FactLoop n p
        -> Heap n p
        -> AccumulatorHeap n
        -> AsAt (BubbleGumFact, BaseValue)
        -> Either (RuntimeError n p) (AccumulatorHeap n)

evalLoop evalPrim now (FactLoop _ bind stmts) xh ah input
 -- Just go through all the statements
 = evalStmt evalPrim now xh' input ah stmts
 where
  xh' = Map.insert bind streamvalue xh
  streamvalue = VBase $ VPair (snd $ fact input) (VDateTime $ time input)


-- | Evaluate a single statement for a single value
evalStmt
        :: Ord n
        => XV.EvalPrim n p
        -> DateTime
        -> Heap n p
        -> AsAt (BubbleGumFact, BaseValue)
        -> AccumulatorHeap n
        -> Statement n p
        -> Either (RuntimeError n p) (AccumulatorHeap n)

evalStmt evalPrim now xh input ah stmt
 = case stmt of
    If x stmts elses
     -> do  v   <- eval x >>= baseValue
            case v of
             -- Run "then" or "else"?
             VBool True
              -> go' stmts
             VBool False
              -> go' elses
             _-> Left (RuntimeErrorIfNotBool v)

    -- Evaluate and insert the value into the heap.
    Let n x stmts
     -> do  v <- eval x
            go (Map.insert n v xh) ah stmts

    Foreach n from to stmts
     -> do  fromv <- eval from >>= baseValue
            tov   <- eval to   >>= baseValue
            case (fromv, tov) of
             (VInt fromi, VInt toi)
              -> -- Open-closed interval [from,to)
                 -- ie "foreach i in 0 to 0" does not run
                 foldM (\ah' index -> go (Map.insert n (VBase $ VInt index) xh) ah' stmts)
                         ah
                       [fromi .. toi-1]
             _
              -> Left $ RuntimeErrorForeachNotInt fromv tov

    Block stmts
     -> foldM (go xh) ah stmts


    -- Read from an accumulator
    Read n acc stmts
     -> do  -- Get the current value and apply the function
            v   <- case Map.lookup acc ah of
                    Just (_, AVFold _ vacc)
                     -> return $ VBase vacc
                    Just (_, AVMutable vacc)
                     -> return $ VBase vacc
                    _
                     -> Left (RuntimeErrorLoopAccumulatorBad n)
            go (Map.insert n v xh) ah stmts

    -- Update accumulator
    Write n x
     -> do  v   <- eval x >>= baseValue
            updateOrPush ah n (fst $ fact input) v

    -- Push a value to a latest accumulator.
    Push n x
     -> do  v   <- eval x >>= baseValue
            updateOrPush ah n (fst $ fact input) v

 where
  -- Go through all the substatements
  go xh' = evalStmt evalPrim now xh' input
  go' = go xh ah

  -- Raise Exp error to Avalanche
  eval = mapLeft RuntimeErrorLoop
       . XV.eval evalPrim xh

