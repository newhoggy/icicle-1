-- | Simplifying and transforming statements
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE TupleSections     #-}

module Icicle.Avalanche.Statement.Simp (
    pullLets
  , convertValues
  , forwardStmts
  , renameReads
  , substXinS
  , thresher
  , nestBlocks
  , dead
  ) where

import              Icicle.Avalanche.Statement.Statement
import              Icicle.Avalanche.Statement.Simp.ExpEnv
import              Icicle.Avalanche.Statement.Simp.Dead
import              Icicle.Avalanche.Prim.Flat

import              Icicle.Common.Base
import              Icicle.Common.Exp
import              Icicle.Common.Exp.Simp.Beta
import              Icicle.Common.FixT
import              Icicle.Common.Fresh
import              Icicle.Common.Type

import              P

import              Data.Functor.Identity
import qualified    Data.HashSet as HashSet
import qualified    Data.Map as Map
import qualified    Data.List as List
import              Data.Hashable (Hashable)

import              Control.Monad.Trans.Class


convertValues :: a -> Statement a n Prim -> Statement a n Prim
convertValues a_fresh statements
 = runIdentity
 $ transformUDStmt trans () statements
 where
  trans _ s
   = case s of
      If  x subs elses
       -> go $ If (goX x) subs elses
      Let n x subs
       -> go $ Let n (goX x) subs
      ForeachInts n from to subs
       -> go $ ForeachInts n (goX from) (goX to) subs
      Write n x
       -> go $ Write n (goX x)
      _ -> return ((), s)

  go x
    = return ((), x)

  goX xx
   = case xx of
       XValue _ (BufT n t) v
        -> goB xx n t v
       XValue _ (ArrayT t) v
        -> goA xx t v
       XApp a x1 x2
        -> XApp a (goX x1) (goX x2)
       XLam a n t x
        -> XLam a n t (goX x)
       XLet a n x1 x2
        -> XLet a n (goX x1) (goX x2)
       _ -> xx

  goB xx n t v
   = case v of
       VBuf buf
         -> bufPrim n t (reverse buf)
       _ -> xx

  goA xx t v
   = case v of
       VArray arr
         -> arrPrim 0 (XValue a_fresh IntT (VInt (length arr))) t arr
       _ -> xx

  bufPrim n t b
   = case b of
       []
         -> XPrim a_fresh (PrimBuf (PrimBufMake n t))
              `xApp`  XValue a_fresh UnitT VUnit
       (x : xs)
         -> XPrim a_fresh (PrimBuf (PrimBufPush n t))
              `xApp` bufPrim n t xs
              `xApp` XValue a_fresh t x

  arrPrim i n t a
    = case a of
         []
           -> XPrim a_fresh (PrimUnsafe (PrimUnsafeArrayCreate t))
               `xApp` n
         (x : xs)
           -> XPrim a_fresh (PrimUpdate (PrimUpdateArrayPut t))
                `xApp` arrPrim (i + 1) n t xs
                `xApp` (XValue a_fresh IntT (VInt i))
                `xApp` XValue a_fresh t x

  xApp
   = XApp a_fresh


pullLets :: Statement a n p -> Statement a n p
pullLets statements
 = runIdentity
 $ transformUDStmt trans () statements
 where
  trans _ s
   = case s of
      If x subs elses
       -> pres x $ \x' -> If x' subs elses
      Let n x subs
       -> pres x $ \x' -> Let n x' subs

      ForeachInts n from to subs
       -> pres2 from to $ \from' to' -> ForeachInts n from' to' subs

      InitAccumulator (Accumulator n vt x) subs
       -> pres x $ \x' -> InitAccumulator (Accumulator n vt x') subs

      Write n x
       -> pres x $ Write n

      Output n t xs
       -> presN xs $ Output n t

      _
       -> return ((), s)

  pres x instmt
   = let (bs, x') = takeLets x
     in  return ((), foldr mkLet (instmt x') bs)

  pres2 x y instmt
   = let (bs, x') = takeLets x
         (cs, y') = takeLets y
     in  return ((), foldr mkLet (instmt x' y') (bs<>cs))

  presN xts instmt
   = let ts  = fmap snd xts
         bxs = fmap (takeLets . fst) xts
         bs  = concat (fmap fst bxs)
         xs  = List.zip (fmap snd bxs) ts
     in  return ((), foldr mkLet (instmt xs) bs)

  mkLet (n,x) s
   = Let n x s


-- | Let-forwarding on statements
forwardStmts :: (Hashable n, Eq n) => a -> Statement a n p -> FixT (Fresh n) (Statement a n p)
forwardStmts a_fresh statements
 = transformUDStmt trans () statements
 where
  trans _ s
   = case s of
      Let n x ss
       | isSimpleValue x
       -> do    s' <- lift $ substXinS a_fresh n x ss
                progress ((), s')

      _ -> return ((), s)


-- | Funky renaming for C
-- Rename reads from accumulators to refer to the accumulator name.
-- This is an awful hack, but means that instead of outputting in the C version
--
-- > read     = acc$read                /* Read */
-- > acc$read = buf_push(read, ...)     /* Write */
--
-- we should end up with
--
-- > acc$read = acc$read                /* Read */
-- > acc$read = buf_push(acc$read, ...) /* Write */
--
-- and the C compiler should be able to get rid of the first, etc.
--
renameReads :: (Hashable n, Eq n) => a -> Statement a n p -> FixT (Fresh n) (Statement a n p)
renameReads a_fresh statements
 = transformUDStmt trans () statements
 where
  trans _ s
   = case s of
      Read nm acc vt ss
       | Just (pre, post) <- splitWrite acc mempty ss
       , nm /= acc
       , not $ HashSet.member nm $ stmtFreeX post
       -> do    pre' <- lift $ substXinS a_fresh nm (XVar a_fresh acc) pre
                progress ((), Read acc acc vt (pre' <> post))
      _ -> return ((), s)

  splitWrite acc seen (Write acc' xx)
   | acc == acc'
   = Just (seen <> Write acc xx, mempty)

  splitWrite acc seen (Block (ss:rest))
   | Just (pre,post) <- splitWrite acc seen ss
   = Just (pre, post <> Block rest)

  splitWrite acc seen (Read nm' acc' vt' ss')
   | acc /= acc'
   , Just (pre,post) <- splitWrite acc seen ss'
   , not $ HashSet.member nm' $ stmtFreeX pre
   = Just (pre, Read nm' acc' vt' post)

  splitWrite acc seen (Block (ss:rest))
   | Nothing <- splitWrite acc seen ss
   = splitWrite acc (seen <> ss) (Block rest)

  splitWrite _ _ _
   = Nothing


-- Substitute an expression into a statement.
--
-- It is important not to substitute shadowed variables:
-- > subst monkey := banana
-- > in (monkey + let monkey = not_banana in monkey)
-- here the inner "let monkey" is a different variable and must not be substituted.
--
-- This is incomplete, does not perform renaming.
-- > subst monkey := banana
-- > in (let banana = 5 in monkey)
-- here, simply substituting would change the meaning.
--
-- Instead we need to rename the local let
-- 
-- > let banana' = 5
-- > in subst monkey := banana
-- > in (subst banana := banana' in monkey)
--
substXinS :: (Hashable n, Eq n) => a -> Name n -> Exp a n p -> Statement a n p -> Fresh n (Statement a n p)
substXinS a_fresh name payload statements
 = transformUDStmt trans True statements
 where
  -- Do nothing; the variable has been shadowed
  trans False s
   = return (False, s)
  trans True s
   = case s of
      If x ss es
       -> sub1 x $ \x' -> If x' ss es

      Let n x ss
       | n == name
       -> do x' <- sub x
             finished (Let n x' ss)
       | HashSet.member n frees
       -> freshen n ss $ \n' ss' -> Let n' x ss'
       | otherwise
       -> sub1 x $ \x' -> Let n x' ss

      ForeachInts n from to ss
       | n == name
       -> finished s
       | HashSet.member n frees
       -> freshen n ss $ \n' ss' -> ForeachInts n' from to ss'
       | otherwise
       -> do    from' <- sub from
                to'   <- sub to
                return (True, ForeachInts n from' to' ss)

      InitAccumulator (Accumulator n vt x) ss
       -> sub1 x $ \x' -> InitAccumulator (Accumulator n vt x') ss

      Write n x
       -> sub1 x $ Write n

      Output n t xs
       -> subN xs $ Output n t

      Read n x z ss
       | n == name
       -> finished s
       | HashSet.member n frees
       -> freshen n ss $ \n' ss' -> Read n' x z ss'

      ForeachFacts ns x y ss
       | name `elem` fmap fst ns
       -> finished s
       | any (flip HashSet.member frees . fst) ns
       -> freshenForeach [] ns x y ss

      _
       -> return (True, s)

  sub = subst a_fresh name payload
  sub1 x f
   = do x' <- sub x
        return (True, f x')

  subN xts f
   = do let ts = fmap snd xts
        xs <- traverse (sub . fst) xts
        let xts' = List.zip xs ts
        return (True, f xts')

  finished s
   = return (False, s)

  freshen n ss f
   = do n' <- fresh
        ss' <- substXinS a_fresh n (XVar a_fresh n') ss
        trans True (f n' ss')

  freshenForeach ns [] x y ss
   = return (True, ForeachFacts ns x y ss)
  freshenForeach ns ((n,t):ns') x y ss
   = do n'  <- fresh
        ss' <- substXinS a_fresh n (XVar a_fresh n') ss
        freshenForeach (ns <> [(n',t)]) ns' x y ss'

  frees = freevars payload


-- | Thresher transform - throw out the chaff.
-- Three things:
--  * Find let bindings that have already been bound:
--      keep an environment of previously bound expressions,
--      at each let binding check if it's already been seen.
--  * Remove let bindings that are not mentioned:
--      check freevariables of free statement.
--  * Remove some other useless code:
--      statements that do not update accumulators or return a value are silly.
--
thresher :: (Hashable n, Eq n, Eq p) => a -> Statement a n p -> FixT (Fresh n) (Statement a n p)
thresher a_fresh statements
 = transformUDStmt trans emptyExpEnv statements
 where
  trans env s
   -- Check if it actually does anything:
   -- updates accumulators, returns a value, etc.
   -- If it doesn't, we might as well return a nop
   | not $ hasEffect s
   = case s of
      -- Don't count it as progress if it is already a nop
      Block [] -> return   (env, mempty)
      _        -> progress (env, mempty)

   | otherwise
   = case s of
      -- Unmentioned let - just return the substatement
      Let n x ss
       | not $ HashSet.member n $ stmtFreeX ss
       -> return (env, ss)
      -- Duplicate let: change to refer to existing one
      -- I tried to use simple equality for simpFlattened since expressions cannot contain lambdas, but it was slower. WEIRD.
       | ((n',_):_) <- filter (\(_,x') -> x `alphaEquality` x') $ Map.toList env
       -> progress (env, Let n (XVar a_fresh n') ss)

      -- Read that's never used
      Read n _ _ ss
       | not $ HashSet.member n $ stmtFreeX ss
       -> progress (env, ss)

      InitAccumulator (Accumulator n _ x) ss
       | usage <- accumulatorUsed n ss
       , not (accRead usage) || not (accWritten usage)
       -> do    n' <- lift $ fresh
                let ss' = Let n' x (killAccumulator n (XVar a_fresh n') ss)
                progress (env, ss')

      If (XValue _ _ (VBool b)) t f
       -> let s' = if b then t else f
          in  progress (updateExpEnv s' env, s')

      -- Anything else, we just update environment and recurse
      _
       -> return (updateExpEnv s env, s)


-- | Check whether a statement writes to any accumulators or returns a value.
-- If it does not update or return, it is probably dead code.
--
-- The first argument is a set of accumulators to ignore.
hasEffect :: (Hashable n, Eq n) => Statement a n p -> Bool
hasEffect statements
 = runIdentity
 $ foldStmt down up (||) HashSet.empty False statements
 where
  down ignore   s
   -- We can ignore the newly created var
   -- because any changes will go out of scope:
   -- externally any updates are pure.
   | InitAccumulator acc _ <- s
   = return $ HashSet.insert (accName acc) ignore
   | otherwise
   = return   ignore

  up   ignore r s
    -- Looping over facts is an effect
   | ForeachFacts _ _ FactLoopNew _ <- s
   = return True

   -- Writing or pushing is an effect,
   -- unless we're explicitly ignoring this accumulator
   | Write n _ <- s
   = return $ not $ HashSet.member n ignore

    -- Outputting is an effect
   | Output _ _ _       <- s
   = return True

    -- Marking a fact as used is an effect.
   | KeepFactInHistory  <- s
   = return True

   | LoadResumable _ _  <- s
   = return True
   | SaveResumable _ _  <- s
   = return True


   -- If any substatements have an effect, the superstatement does.
   | otherwise
   = return r


-- | Find free *expression* variables in statements.
-- Note that this ignores accumulators, as they are a different scope.
stmtFreeX :: (Hashable n, Eq n) => Statement a n p -> HashSet.HashSet (Name n)
stmtFreeX statements
 = runIdentity
 $ foldStmt down up HashSet.union () HashSet.empty statements
 where
  down _ _
   = return ()

  up _ subvars s
   = let ret x = return (freevars x `HashSet.union` subvars)
     in  case s of
          -- Simply recursion for most cases
          If x _ _
           -> ret x
          -- We want the free variables of x,
          -- but need to hide "n" from the free variables of ss:
          -- n is not free in there any more.
          Let n x _
           -> return (freevars x `HashSet.union` HashSet.delete n subvars)
          ForeachInts n x y _
           -> return (freevars x `HashSet.union` freevars y `HashSet.union` HashSet.delete n subvars)

          -- Accumulators are in a different scope,
          -- so the binding doesn't hide anything.
          -- Still check the initialise expression though.
          InitAccumulator acc _
           -> ret (accInit acc)

          -- We're binding a new expression variable from an accumulator.
          -- The accumulator doesn't matter - but we need to hide n from
          -- the substatement's free variables.
          Read n _ _ _
           -> return (HashSet.delete n subvars)

          -- Leaves that use expressions.
          -- Here, the name is an accumulator variable, so doesn't affect expressions.
          Write _ x
           -> ret x
          Output _ _ xs
           -> return (HashSet.unions (fmap (freevars . fst) xs) `HashSet.union` subvars)

          -- Leftovers: just the union of the under bits
          _
           -> return subvars


-- | Nest blocks in further.
-- for example,
--
-- > Block [ Let x (Let y ...)
-- >       , baloney ]
--
-- could be translated to
--
-- > Let x $
-- > Block [ Let y ...
-- >       , baloney ]
-- 
-- this does not affect semantics so long as x isn't free in baloney.
-- In fact, it doesn't do anything except allowing thresher to
-- remove more duplicates.
--   
-- Note that the above example is only one step: nesting would then be
-- recursively performed etc.
nestBlocks :: (Hashable n, Eq n) => a -> Statement a n p -> Fresh n (Statement a n p)
nestBlocks a_fresh statements
 = transformUDStmt trans () statements
 where
  trans _ s
   = case s of
      Block bs
        -> goBlock (concatMap catBlock bs) []
      _ -> return ((), s)


  goBlock [] [pre]
   = return ((), pre)
  goBlock [] pres
   = return ((), Block $ reverse pres)

  goBlock (Let n x inner : baloney : ls) pres
   = do (n',inner') <- maybeRename n baloney inner
        goBlock (Let n' x (inner' <> baloney) : ls) pres

  goBlock (InitAccumulator acc inner : baloney : ls) pres
   = do goBlock (InitAccumulator acc (inner <> baloney) : ls) pres

  goBlock (Read nx nacc vt inner : baloney : ls) pres
   = do (nx',inner') <- maybeRename nx baloney inner
        goBlock (Read nx' nacc vt (inner' <> baloney) : ls) pres

  goBlock (skip : ls) pres
   = goBlock ls (skip : pres)

  -- concatMap catBlock
  -- should flatten out the nested blocks
  catBlock (Block bs)
   = bs
  catBlock b
   = [b]

  -- Check if we need to rename the let binding - and do it
  maybeRename n check inner
   | n `HashSet.member` stmtFreeX check
   = do n'      <- fresh
        inner'  <- substXinS a_fresh n (XVar a_fresh n') inner
        return (n', inner')

   | otherwise
   =    return (n, inner)



data AccumulatorUsage
 = AccumulatorUsage
 { accRead    :: Bool
 , accWritten :: Bool }

-- | Check whether statement uses this accumulator
accumulatorUsed :: (Hashable n, Eq n) => Name n -> Statement a n p -> AccumulatorUsage
accumulatorUsed acc statements
 = runIdentity
 $ foldStmt down up ors () (AccumulatorUsage False False) statements
 where
  ors (AccumulatorUsage a b) (AccumulatorUsage c d) = AccumulatorUsage (a || c) (b || d)

  down _ _ = return ()

  up _ r s
   -- Writing or pushing is an effect,
   -- unless we're explicitly ignoring this accumulator
   | Write n _ <- s
   , n == acc
   = return (AccumulatorUsage True False)

   | Read _ n _ _ <- s
   , n == acc
   = return (ors r (AccumulatorUsage False True))

   | otherwise
   = return r

