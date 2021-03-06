{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeInType          #-}

module Snowdrop.Core.Expand.Type
       ( SeqExpanders
       , SeqExp (..)
       , SeqExpander
       , PreExpander (..)
       , contramapSeqExpander
       , contramapPreExpander
       , DiffChangeSet (..)

       , ExpRestriction (..)
       , ExpInpComps
       , ExpOutComps
       , SeqExpanderComponents
       ) where

import           Universum

import           Data.Default (Default (..))
import           Data.Vinyl (RMap (..), Rec (..))

import           Snowdrop.Core.ChangeSet (HChangeSet)
import           Snowdrop.Core.ERoComp (ERoComp)
import           Snowdrop.Core.Transaction (ExpRestriction (..), SeqExpanderComponents, TxRaw)

type SeqExpanders conf = Rec (SeqExp conf)

newtype SeqExp conf txtype = SeqExp {unSeqExp :: SeqExpander conf txtype}

-- | Sequence of expand stages to be consequently executed upon a given transaction.
type SeqExpander conf txtype = Rec (PreExpander conf (TxRaw txtype)) (SeqExpanderComponents txtype)

contramapSeqExpander
  :: RMap xs
  => (a -> b)
  -> Rec (PreExpander conf b) xs
  -> Rec (PreExpander conf a) xs
contramapSeqExpander f = rmap (contramapPreExpander f)

-- | PreExpander allows you to convert one raw tx to StateTx.
--  _inpSet_ is set of Prefixes which expander gets access to during computation.
--  _outSet_ is set of Prefixes which expander returns as id of ChangeSet.
--  expanderAct takes raw tx, returns addition to txBody.
--  So the result StateTx is constructed as
--  _StateTx proofFromRawTx (addtionFromExpander1 <> additionFromExpander2 <> ...)_
newtype PreExpander conf rawTx ioRestr = PreExpander
    { runExpander :: rawTx
                  -> ERoComp conf (ExpInpComps ioRestr) (DiffChangeSet (ExpOutComps ioRestr))
    }

instance Semigroup (DiffChangeSet (ExpOutComps ioRestr)) =>
    Semigroup (PreExpander conf rawTx ioRestr) where
    PreExpander a <> PreExpander b = PreExpander $ a <> b

contramapPreExpander :: (a -> b) -> PreExpander conf b ioRestr -> PreExpander conf a ioRestr
contramapPreExpander f (PreExpander act) = PreExpander $ act . f

-- | DiffChangeSet holds changes which one expander returns
newtype DiffChangeSet xs = DiffChangeSet {unDiffCS :: HChangeSet xs}

deriving instance Eq (HChangeSet xs) => Eq (DiffChangeSet xs)
deriving instance Show (HChangeSet xs) => Show (DiffChangeSet xs)
deriving instance Semigroup (HChangeSet xs) => Semigroup (DiffChangeSet xs)
deriving instance Monoid (HChangeSet xs) => Monoid (DiffChangeSet xs)
deriving instance Default (HChangeSet xs) => Default (DiffChangeSet xs)

type family ExpInpComps r where ExpInpComps ('ExRestriction i o) = i
type family ExpOutComps r where ExpOutComps ('ExRestriction i o) = o
