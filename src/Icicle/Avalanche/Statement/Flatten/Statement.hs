-- | Turn Core primitives into Flat - removing the folds
-- The input statements must be in A-normal form.
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Avalanche.Statement.Flatten.Statement (
    flatten
  ) where

import              Icicle.Avalanche.Statement.Flatten.Base
import              Icicle.Avalanche.Statement.Flatten.Exp

import              Icicle.Avalanche.Statement.Statement

import qualified    Icicle.Core.Exp.Prim           as Core

import              Icicle.Internal.Pretty

import              P

import qualified    Data.List                      as List
import              Data.Hashable                  (Hashable)


-- Extracting FactIdentifiers from Buffers:
--
-- Need to make flatten go through and change types too:
--      Buf t -> (Buf FactIdentifier, Buf t)
-- We need a tuple of Bufs rather than Buf of tuple here, to implement LatestRead (easily) 
-- 
-- Expression rewrites:
--      LatestPush b f v -> (BufPush (fst b) f, BufPush (snd b) v)
--      LatestRead b     -> BufRead (snd b)
-- 
-- We also need to modify literal XValue Bufs:
--      Buf []           -> (Buf [], Buf [])
--
--
-- Finally, after the end of the ForeachFacts loop, we need to go through the FactIdentifier buffers and
-- call KeepFactInHistory for each FactIdentifier.
-- This is a bit trickier than you might think:
--  1. Bufs might be nested inside other places, like inside Maps or inside tuples
--  2. We won't necessarily read from all the bufs, but bufs we don't read might be important next time
--    (Imagine we have a Map of Bufs, and we choose one entry to read the values from and return.
--     The next time we run, we might not choose the same entry, so we need to make sure all the Bufs are saved)
--
-- So, we need to modify flatten to keep track of all Accumulators in scope (or perhaps only accumulators with nested Buf types).
-- For each accumulator, we need to generate code for traversing the structure and finding the nested Bufs.
-- When we find the Buf, we can read the fact identifiers and mark them as necessary.
--
-- (It might be worth storing each accumulator's original type, rather than the modified/tupled type,
-- as searching for a Buf is probably easier than searching for the first element in tuple of two bufs)

-- | Flatten the primitives in a statement.
-- This just calls @flatX@ for every expression, wrapping the statement.
flatten :: (Pretty n, Hashable n, Eq n)
        => a
        -> Statement a n Core.Prim
        -> FlatM a n
flatten a_fresh s
 = case s of
    If x ts es
     -> flatX a_fresh x
     $ \x'
     -> If x' <$> flatten a_fresh ts <*> flatten a_fresh es

    Let n x ss
     -> flatX a_fresh x
     $ \x'
     -> Let n x' <$> flatten a_fresh ss

    ForeachInts n from to ss
     -> flatX a_fresh from
     $ \from'
     -> flatX a_fresh to
     $ \to'
     -> ForeachInts n from' to' <$> flatten a_fresh ss

    ForeachFacts binds vt lo ss
     -> ForeachFacts binds vt lo <$> flatten a_fresh ss

    Block ss
     -> Block <$> mapM (flatten a_fresh) ss

    InitAccumulator acc ss
     -> flatX a_fresh (accInit acc)
     $ \x'
     -> InitAccumulator (acc { accInit = x' }) <$> flatten a_fresh ss

    Read n m vt ss
     -> Read n m vt <$> flatten a_fresh ss

    Write n x
     -> flatX a_fresh x (return . Write n)

    Output n t xts
     | xs <- fmap fst xts
     , ts <- fmap snd xts
     -> flatXS a_fresh xs []
     $ \xs'
     -> return $ Output n t (List.zip xs' ts)

    KeepFactInHistory x
     -> flatX a_fresh x (return . KeepFactInHistory)

    LoadResumable n t
     -> return $ LoadResumable n t
    SaveResumable n t
     -> return $ SaveResumable n t


