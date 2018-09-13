module Snowdrop.Core.Validator.Types
       ( PreValidator (..)
       , mkPreValidator
       , Validator
       , mkValidator
       , runValidator
       , upcastPreValidator
       , downcastPreValidator
       , castPreValidator
       , fromPreValidator
       , getPreValidator
       ) where

import           Universum

import           Control.Monad.Except (throwError)
import           Data.Vinyl

import           Snowdrop.Core.ERoComp.Types
import           Snowdrop.Core.Transaction

import           Snowdrop.Util (HasGetter, HasPrism (..), RContains)

-- | Function which validates transaction, assuming a transaction
-- of appropriate type is supplied.
-- It's expected to project some id types and validate them alone
-- without considering other id types.
newtype PreValidator e id value ctx txtype =
    PreValidator { runPrevalidator :: StateTx id value txtype -> ERoComp e id value ctx () }

-- | Alias for $PreValidator constructor
mkPreValidator
    :: (StateTx id value txtype -> ERoComp e id value ctx ())
    -> PreValidator e id value ctx txtype
mkPreValidator = PreValidator

-- | Object to validate transaction fully.
-- Contains a mapping from transaction type to a corresponding pre-validator
-- (which may be a concatenation of few other pre-validators).
-- Each entry in the mapping (a pre-validator) is expected to fully validate
-- the transaction, consider all id types in particular.
type Validator e id value ctx (txtypes :: [*]) = Rec (PreValidator e id value ctx) txtypes

instance Ord id => Semigroup (PreValidator e id value ctx txtype) where
     PreValidator a <> PreValidator b = PreValidator $ a <> b

instance Ord id => Monoid (PreValidator e id value ctx txtype) where
    mempty = PreValidator $ const (pure ())
    mappend = (<>)

-- | Smart constructor for $Validator type
mkValidator ::
    Ord id
    => [PreValidator e id value ctx txtype]
    -> Validator e id value ctx '[txtype]
mkValidator ps = mconcat ps :& RNil

fromPreValidator :: PreValidator e id value ctx txtype -> Validator e id value ctx '[txtype]
fromPreValidator ps = ps :& RNil

getPreValidator :: Validator e id value ctx '[txtype] -> PreValidator e id value ctx txtype
getPreValidator (ps :& RNil) = ps

-- | Execute validator on a given transaction.
runValidator
    :: forall e id txtype value ctx txtypes . (RContains txtypes txtype)
    => Validator e id value ctx txtypes
    -> StateTx id value txtype
    -> ERoComp e id value ctx ()
runValidator prevalidators statetx =
    runPrevalidator (rget (Proxy @txtype) prevalidators) statetx

-- | TODO: consider renaming to make those more consistent with Validator casts
--
-- Current naming is inspired by bubtyping relationship:
-- * cast from child to parent (from concrete to more general type) is an upcast and it never fails
-- * cast from parent to child (from more general to concrete type) is a downcast and can fail
-- But it can be viewed slightly differently when considering Validators and other more tricky types.
upcastPreValidator
    :: forall id value txtype1 txtype2 e ctx . HasGetter (TxProof txtype2) (TxProof txtype1)
    => PreValidator e id value ctx txtype1
    -> PreValidator e id value ctx txtype2
upcastPreValidator prev = PreValidator $ runPrevalidator prev . downcastStateTx

downcastPreValidator
    :: forall id value txtype1 txtype2 e ctx . HasPrism (TxProof txtype2) (TxProof txtype1)
    => e
    -> PreValidator e id value ctx txtype1
    -> PreValidator e id value ctx txtype2
downcastPreValidator err prev = PreValidator $ maybe (throwError err) (runPrevalidator prev) . upcastStateTx

castPreValidator
    :: forall id value txtype1 txtype2 e ctx .
       e
    -> (TxProof txtype2 -> Maybe (TxProof txtype1))
    -> PreValidator e id value ctx txtype1
    -> PreValidator e id value ctx txtype2
castPreValidator err castProof prev = PreValidator $ maybe (throwError err) (runPrevalidator prev) . castStateTx castProof
