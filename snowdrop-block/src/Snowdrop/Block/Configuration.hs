{-# LANGUAGE Rank2Types #-}

module Snowdrop.Block.Configuration
       ( BlockIntegrityVerifier (..)
       , BlkConfiguration (..)
       ) where

import qualified Prelude as P
import           Universum

import           Snowdrop.Block.Types (BlockHeader, BlockRef, CurrentBlockRef (..), OSParams,
                                       PrevBlockRef (..), RawBlk)
import           Snowdrop.Util (OldestFirst (..), VerRes)

newtype BlockIntegrityVerifier blkType = BIV { unBIV :: RawBlk blkType -> VerRes Text () }

instance Semigroup (BlockIntegrityVerifier blkType) where
    BIV f <> BIV g = BIV $ \rawB -> f rawB <> g rawB

instance Monoid (BlockIntegrityVerifier blkType) where
    mempty = BIV mempty
    BIV f `mappend` BIV g = BIV $ \rawB -> f rawB <> g rawB

-- | Block validation configuration. Contains necessary methods for to perform structural
-- validation of block sequence (chain) and come up with decision on whether
-- the sequence shall be applied instead of currently adopted "best" chain.
-- All methods presented in block validation configuration are stateless, all stateful checks shall
-- be performed as part of individual transaction validation (which is encapsulated in `bscApplyPayload`
-- method of block handling configuration `BlkStateConfiguration`.
data BlkConfiguration blkType = BlkConfiguration
    { bcBlockRef     :: BlockHeader blkType -> CurrentBlockRef (BlockRef blkType)
    -- ^ Get a block reference by given header.
    -- Normally to be represented by function to get header hash
    -- (with header including hashes of data within the block).

    , bcPrevBlockRef :: BlockHeader blkType -> PrevBlockRef (BlockRef blkType)
    -- ^ Get reference of the block preceding the block, which header is given.
    -- Returns `Nothing` in case of supplied header referring to the very first
    -- block of blockchain (a la block with difficulty 1).

    , bcBlkVerify    :: BlockIntegrityVerifier blkType
    -- ^ Block integrity verifier: a pure function which given a block returns True iff
    -- the block is valid with respect to its integrity.
    -- This includes checks of all invariants that rely on:
    --
    -- * particular order or relation between transactions in block;
    -- * existience or non-existence of particular transactions in block;
    -- * relation between block payload and header, e.g. header containing a hash of payload.
    --
    -- Block integrity verifier is by intention made a pure function:
    -- all stateful checks shall be made in scope of validators for individual transactions.

    , bcIsBetterThan :: OldestFirst [] (BlockHeader blkType) -> OldestFirst NonEmpty (BlockHeader blkType) -> Bool
    -- ^ Comparison of two chains.
    -- Left operand is the currently adopted "best" chain, right operand is a proposed
    -- chain. `bcIsBetterThan` function is to make up a decision on whether proposed block
    -- sequence is better (stronger) than currently adopted.
    --
    -- If `bcIsBetterThan` returns `True`,
    -- it means that if proposed chain is considered valid over the latter course of validation, it
    -- is to be applied instead of currently adopted "best" chain.

    , bcValidateFork :: OSParams blkType -> OldestFirst NonEmpty (BlockHeader blkType) -> VerRes Text ()
    -- ^ Check of chain with OS Params.

    , bcMaxForkDepth :: Int
    -- ^ Parameter denoting the maximal depth of Lowest Common Ancestor (LCA) of two chains in
    -- the currently adopted "best" chain.
    -- First block of proposed chain is assumed to have previous block reference to be an
    -- existing block in the currently adopted "best" chain (which is called an LCA of two chains).
    --
    -- If the LCA block is more than `bcMaxForkDepth` blocks behind the most recent block of
    -- currently adopted "best" chain, the proposed chain is considered invalid
    -- (and won't be applied instead of currently adopted "best" chain).
    --
    -- Parameter `bcMaxForkDepth` gives advise for implementation on how deep to inspect into
    -- currently adopted "best" chain in order to compare currently adopted chain with proposed one.
    -- Most of existing consensus protocols (including that behind such cryptocurrencies as Bitcoin,
    -- Ethereum, Cardano) either directly or inherently provide possibility to define a particular
    -- value for `bcMaxForkDepth`. In case, such definition is impossible to come up with,
    -- `maxBound @Int` is advised to be used as value.
    }
