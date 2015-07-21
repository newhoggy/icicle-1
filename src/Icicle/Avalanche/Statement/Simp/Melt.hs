{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Avalanche.Statement.Simp.Melt (
    melt
  ) where

import              Icicle.Avalanche.Prim.Flat
import qualified    Icicle.Common.Exp.Prim.Minimal as Min
import              Icicle.Avalanche.Statement.Statement

import              Icicle.Common.Base
import              Icicle.Common.Exp
import              Icicle.Common.Fresh
import              Icicle.Common.Type

import              P

import qualified    Data.Map            as Map

-- TODO
melt :: Ord n
     => Statement n Prim
     -> Fresh n (Statement n Prim)
melt statements
 = transformUDStmt goS Map.empty statements
 where
  goS env s
   = do env' <- updateEnv env s
        s'<-case s of
             InitAccumulator (Accumulator n at _ x) ss
              | Just (Latest,PairT a b,[na,nb]) <- Map.lookup n env'
              -> return
               $ InitAccumulator (Accumulator na at a x)
               $ InitAccumulator (Accumulator nb at b x)
               $ ss

              | Just (Mutable,PairT a b,[na,nb]) <- Map.lookup n env'
              -> return
               $ InitAccumulator (Accumulator na at a (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairFst a b) `XApp` x))
               $ InitAccumulator (Accumulator nb at b (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairSnd a b) `XApp` x))
               $ ss

              | Just (Mutable,UnitT,[]) <- Map.lookup n env'
              -> return $ ss


             Read n acc ss
              | Just (Latest, PairT _ _, [na,nb]) <- Map.lookup acc env'
              -> do n1 <- freshPrefix' n
                    n2 <- freshPrefix' n
                    ss'<- transformX return (return . arrayOfPairs n n1 n2) ss
                    return $ Read n1 na
                           $ Read n2 nb
                             ss'

              | Just (Mutable, PairT ta tb, [na,nb]) <- Map.lookup acc env'
              -> do n1 <- freshPrefix' n
                    n2 <- freshPrefix' n
                    let pair    = XPrim (PrimMinimal $ Min.PrimConst $ Min.PrimConstPair ta tb)
                                `XApp` (XVar n1)
                                `XApp` (XVar n2)
                    ss'<- transformX return (subst n pair) ss
                    return $ Read n1 na
                           $ Read n2 nb
                             ss'

              | Just (Mutable, UnitT, []) <- Map.lookup acc env'
              -> do transformX return (subst n (XValue UnitT VUnit)) ss


             Push n x
              | Just (Latest, PairT a b, [na,nb]) <- Map.lookup n env'
              -> return
               $ Block
               [ Push na (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairFst a b) `XApp` x)
               , Push nb (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairSnd a b) `XApp` x) ]

             Write n x
              | Just (Mutable, PairT a b, [na,nb]) <- Map.lookup n env'
              -> return
               $ Block
               [ Write na (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairFst a b) `XApp` x)
               , Write nb (XPrim (PrimMinimal $ Min.PrimPair $ Min.PrimPairSnd a b) `XApp` x) ]

              | Just (Mutable, UnitT, []) <- Map.lookup n env'
              -> return mempty

             _ -> return s

        return (env', s')

  updateEnv env s
   | InitAccumulator (Accumulator n at vt@(PairT _ _) _) _ <- s
   = do v1 <- freshPrefix' n
        v2 <- freshPrefix' n
        return $ Map.insert n (at,vt,[v1,v2]) env

   | InitAccumulator (Accumulator n Mutable UnitT _) _ <- s
   = do return $ Map.insert n (Mutable,UnitT,[]) env

   | otherwise
   = return env

  arrayOfPairs n n1 n2 x
   | Just (PrimUnsafe (PrimUnsafeArrayIndex (PairT ta tb)), [XVar n', ix]) <- takePrimApps x
   , n == n'
   = XPrim (PrimMinimal $ Min.PrimConst $ Min.PrimConstPair ta tb)
    `XApp` (XPrim (PrimUnsafe (PrimUnsafeArrayIndex ta)) `XApp` XVar n1 `XApp` ix)
    `XApp` (XPrim (PrimUnsafe (PrimUnsafeArrayIndex tb)) `XApp` XVar n2 `XApp` ix)

   | Just (PrimProject (PrimProjectArrayLength (PairT ta _)), [XVar n']) <- takePrimApps x
   , n == n'
   = XPrim (PrimProject (PrimProjectArrayLength ta)) `XApp` XVar n1

   | otherwise
   = x

