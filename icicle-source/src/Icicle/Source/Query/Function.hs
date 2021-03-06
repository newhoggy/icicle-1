{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Source.Query.Function (
    Function       (..)
  , reannotF
  ) where

import                  Icicle.Internal.Pretty
import                  Icicle.Source.Query.Query
import                  Icicle.Common.Base

import                  P

data Function a n
  = Function
  { arguments :: [(a,Name n)]
  , body      :: Query a n }
  deriving (Show, Eq)

reannotF :: (a -> a') -> Function a n -> Function a' n
reannotF f fun
 = fun { arguments = fmap (first f) (arguments fun)
       , body = reannotQ f (body fun) }

instance Pretty n => Pretty (Function a n) where
  pretty q =
    let
      args =
        case reverse $ arguments q of
          [] ->
            [ prettyPunctuation "=" ]
          (_, n0) : xs0 ->
            fmap (\(_, n) -> pretty n) (reverse xs0) <>
            [ pretty n0 <+> prettyPunctuation "=" ]
    in
      vsep $
        args <> [
            indent 2 . pretty $ body q
          ]
