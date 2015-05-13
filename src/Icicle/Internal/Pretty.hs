-- | Provide a *slightly* better interface to pretty printer.
--
-- Problem is that it defines (<>), but so does Data.Monoid.
--
-- Its (<>) really is a monoid though, so hiding it and adding
-- an orphan instance that does the same thing seems fine to me.
--
-- The pretty printer also defines <$> which isn't an applicative.
-- We will just hide that one.
--
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Icicle.Internal.Pretty (
    module PP
    ) where

-- The one we want to export without <> or <$>
import              Text.PrettyPrint.Leijen as PP hiding ((<>), (<$>))
-- The one with <>
import              Text.PrettyPrint.Leijen as PJOIN

import              P

import              Data.Text               as T

instance Monoid Doc where
 mempty  =  PJOIN.empty
 mappend = (PJOIN.<>)

-- We also need to be able to pretty Data.Text...
instance Pretty Text where
 pretty t = text (T.unpack t)
