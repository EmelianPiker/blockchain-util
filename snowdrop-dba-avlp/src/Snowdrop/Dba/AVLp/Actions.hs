{-# LANGUAGE DataKinds           #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE InstanceSigs        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snowdrop.Dba.AVLp.Actions
       ( AVLChgAccum
       , avlServerDbActions
       , avlClientDbActions
       , RememberNodesActs' (..)
       , RememberNodesActs
       ) where

import           Data.Vinyl (RApply(..), RMap, RecApplicative, RecSubset, rget, rpure, rput)
import           Data.Vinyl.TypeLevel (RImage)

import           Universum

import qualified Data.Tree.AVL as AVL

import           Data.Default (Default (def))
import qualified Data.Map.Strict as M
import           Data.Vinyl (Rec (..))
import           Data.Vinyl.Recursive (rmap)
import           Data.Vinyl.Functor (Lift(..))

import           Snowdrop.Core (ChgAccum, Undo)
import           Snowdrop.Dba.AVLp.Accum (AVLChgAccum (..), AVLChgAccums, RootHashes, computeUndo,
                                          iter, modAccum, modAccumU, query)
import           Snowdrop.Dba.AVLp.Avl (AllAvlEntries, AvlHashable, AvlProof (..), AvlProofs,
                                        AvlUndo, IsAvlEntry, RootHash (..), RootHashComp (..),
                                        avlRootHash, mkAVL, saveAVL)
import           Snowdrop.Dba.AVLp.Constraints (RHashable, RMapWithC, rmapWithHash)
import           Snowdrop.Dba.AVLp.State (AVLCache (..), AVLCacheEl, AVLCacheElT, AVLCacheT,
                                          AVLPureStorage (..), AVLServerState (..), ClientTempState,
                                          RetrieveF, asAVLCache, clientModeToTempSt, runAVLCacheElT,
                                          runAVLCacheT, upcastAVLCache, upcastAVLCache')
import           Snowdrop.Dba.Base (ClientMode (..), DbAccessActions (..), DbAccessActionsM (..),
                                    DbAccessActionsU (..), DbApplyProof, DbComponents,
                                    DbModifyActions (..), RememberForProof (..))
import           Snowdrop.Hetero (HKey, HVal, RContains)
import           Snowdrop.Util (NewestFirst)

-- from http://hackage.haskell.org/package/vinyl-0.11.0/docs/src/Data.Vinyl.Core.html#rcombine
-- | Combine two records by combining their fields using the given
-- function. The first argument is a binary operation for combining
-- two values (e.g. '(<>)'), the second argument takes a record field
-- into the type equipped with the desired operation, the third
-- argument takes the combined value back to a result type.
rcombine :: (RMap rs, RApply rs)
         => (forall a. m a -> m a -> m a)
         -> (forall a. f a -> m a)
         -> (forall a. m a -> g a)
         -> Rec f rs
         -> Rec f rs
         -> Rec g rs
rcombine smash toM fromM x y =
  rmap fromM (rapply (rmap (Lift . smash) x') y')
  where x' = rmap toM x
        y' = rmap toM y

ignoreNodesActs :: RecApplicative xs => Rec (Const (Set h -> STM ())) xs
ignoreNodesActs = rpure (Const (\_ -> pure ()))

avlClientDbActions
    :: forall conf h xs .
    ( AvlHashable h
    , RHashable h xs
    , AllAvlEntries h xs
    , Undo conf ~ AvlUndo h xs
    , ChgAccum conf ~ AVLChgAccums h xs
    , DbApplyProof conf ~ ()
    , xs ~ DbComponents conf
    , RecApplicative xs
    , RMapWithC (IsAvlEntry h) xs
    )
    => RetrieveF h STM xs
    -> RootHashes h xs
    -> STM (ClientMode (AvlProofs h xs) -> DbModifyActions conf STM)
avlClientDbActions retrieveF = fmap mkActions . newTVar
  where
    mkActions
        :: TVar (RootHashes h xs)
        -> ClientMode (AvlProofs h xs)
        -> DbModifyActions conf STM
    mkActions var ctMode =
        DbModifyActions (mkAccessActions var ctMode) (apply var)

    mkAccessActions
        :: TVar (RootHashes h xs)
        -> ClientMode (AvlProofs h xs)
        -> DbAccessActionsU conf STM
    mkAccessActions var ctMode = daaU
      where
        daa =
          DbAccessActions
            -- adding keys to amsRequested
          (\cA req -> createState >>= \ctx -> query ctx cA ignoreNodesActs req)
            -- setting amsRequested to AMSWholeTree as iteration with
            -- current implementation requires whole tree traversal
          (\cA -> createState >>= \ctx -> iter ctx cA ignoreNodesActs)
        daaM = DbAccessActionsM daa (\cA cs -> createState >>= \ctx -> modAccum ctx cA cs)
        daaU = DbAccessActionsU daaM
                  (withProjUndo . modAccumU)
                  (\cA _cs -> pure . Right . computeUndo cA =<< createState)
        createState = clientModeToTempSt retrieveF ctMode =<< readTVar var

    apply :: AvlHashable h => TVar (RootHashes h xs) -> AVLChgAccums h xs -> STM ()
    apply var (Just accums) =
        writeTVar var $ rmapWithHash @h (RootHashComp . avlRootHash . acaMap) accums
    apply _ Nothing = pure ()

withProjUndo :: (MonadThrow m, Applicative f) => (NewestFirst [] undo -> a) -> NewestFirst [] undo -> m (f a)
withProjUndo action = pure . pure . action

avlServerDbActions
    :: forall conf h xs .
    ( AvlHashable h
    , AllAvlEntries h xs
    , RHashable h xs

    , RecApplicative xs
    , RememberNodesActs' h xs xs

    , Undo conf ~ AvlUndo h xs
    , ChgAccum conf ~ AVLChgAccums h xs
    , DbApplyProof conf ~ AvlProofs h xs
    , xs ~ DbComponents  conf

    , RMapWithC (IsAvlEntry h) xs
    , ComputeProofAll h (ReaderT (AVLPureStorage h xs) STM) xs
    , RMap xs
    , RApply xs

    -- FIXME
    , Default (AVLCache h xs)
    , Default (AVLCache h '[])
    )
    => AVLServerState h xs
    -> STM ( RememberForProof -> DbModifyActions conf STM
            -- `DbModifyActions` provided by `RememberForProof` object
            -- (`RememberForProof False` for disabling recording for queries performed)
           , RetrieveF h STM xs
            -- Function to retrieve data from server state internal AVL storage
           )
avlServerDbActions = fmap mkActions . newTVar
  where
    -- FIXME:
    retrieveHash :: TVar (AVLServerState h xs) -> RetrieveF h STM xs
    retrieveHash = undefined
    -- retrieveHash var h = M.lookup h . unAVLPureStorage . amsState <$> readTVar var

    mkActions var = (\recForProof ->
                        DbModifyActions
                          (mkAccessActions var recForProof)
                          (apply var),
                        retrieveHash var)
    mkAccessActions var recForProof = daaU
      where
        nodeActs :: Rec (Const (Set h -> STM ())) xs
        nodeActs = case recForProof of
            RememberForProof True  -> rememberNodesActs var
            RememberForProof False -> ignoreNodesActs

        daa = DbAccessActions
                (\cA req -> readTVar var >>= \ctx -> query ctx cA nodeActs req)

                (\cA -> readTVar var >>= \ctx -> iter ctx cA nodeActs)
        daaM = DbAccessActionsM daa (\cA cs -> (readTVar var) >>= \ctx -> modAccum ctx cA cs)
        daaU = DbAccessActionsU daaM
                  (withProjUndo . modAccumU)
                  (\cA _cs -> pure . Right . computeUndo cA =<< (readTVar var))

    apply :: ( RecApplicative xs
             , RMap xs
             , RApply xs
             , ComputeProofAll h (ReaderT (AVLPureStorage h xs) STM) xs )
          => TVar (AVLServerState h xs)
          -> AVLChgAccums h xs
          -> STM (AvlProofs h xs)
    apply var Nothing =
        rmap (AvlProof . AVL.Proof . mkAVL . unRootHashComp) . amsRootHashes <$> (readTVar var)
    apply var (Just accums) =
        applyDo var accums >>= \oldAms -> fst <$>
            runAVLCacheT
              (computeProofAll (amsRootHashes oldAms) accums (amsVisited oldAms))
              def
              (amsState oldAms)

    applyDo
        :: (RMap xs, RApply xs, RecApplicative xs)
        => TVar (AVLServerState h xs)
        -> Rec (AVLChgAccum h) xs
        -> STM (AVLServerState h xs)
    applyDo var accums = do
        s <- readTVar var
        (roots, accCache) <- saveAVLs (amsState s) accums
        let newState = AMS {
              amsRootHashes = roots
            , amsState = AVLPureStorage $ rcombine (<>) id id (unAVLCache accCache) (unAVLPureStorage (amsState s))
            , amsVisited = rpure (Const mempty)
            }
        writeTVar var newState $> s

    saveAVLs :: AllAvlEntries h rs => AVLPureStorage h rs -> Rec (AVLChgAccum h) rs -> STM (RootHashes h rs, AVLCache h rs)
    saveAVLs _ RNil = pure (RNil, def)
    saveAVLs storage (AVLChgAccum accAvl acc _ :& accums) = do
        -- FIXME: took too long to figure out..
        (h, acc) :: (RootHash h, AVLCacheEl h r) <- runAVLCacheElT (saveAVL accAvl) acc storage
        -- (restRoots, restAcc) <- saveAVLs storage accums
        -- pure (RootHashComp h :& restRoots, AVLCache (acc :& unAVLCache restAcc))
        undefined

class Monad m => ComputeProofAll h m xs where
    computeProofAll :: RootHashes h xs
                    -> Rec (AVLChgAccum h) xs
                    -> Rec (Const (Set h)) xs
                    -> AVLCacheT h m xs (AvlProofs h xs)

instance Monad m => ComputeProofAll h m '[] where
    computeProofAll _ _ _ = pure RNil

instance (ComputeProofAll h m xs, IsAvlEntry h x, AvlHashable h, MonadCatch m) => ComputeProofAll h m (x ': xs) where
    computeProofAll :: RootHashes h (x ': xs)
                    -> Rec (AVLChgAccum h) (x ': xs)
                    -> Rec (Const (Set h)) (x ': xs)
                    -> AVLCacheT h m (x ': xs) (AvlProofs h (x ': xs))
    computeProofAll (RootHashComp rootH :& roots) (AVLChgAccum _ _ accTouched :& accums) ((getConst -> req) :& reqs) = do
        proof :: AvlProof h x <- asAVLCache $ AvlProof <$> computeProof rootH accTouched req
        res <- upcastAVLCache' $ computeProofAll roots accums reqs
        pure (proof :& res)

computeProof
    :: forall t h m . (IsAvlEntry h t, AvlHashable h, MonadCatch m)
    => RootHash h
    -> Set h
    -> Set h
    -> AVLCacheElT h m t (AVL.Proof h (HKey t) (HVal t))
computeProof (mkAVL -> oldAvl) accTouched requested =
        AVL.prune (accTouched <> requested) $ oldAvl

type RememberNodesActs h xs = RememberNodesActs' h xs xs

-- Build record where each element is an effectful action which appends set of
-- hashes to a set which belongs to a given record component
class RememberNodesActs' h ys xs where
    rememberNodesActs :: TVar (AVLServerState h ys) -> Rec (Const (Set h -> STM ())) xs

instance RememberNodesActs' h ys '[] where
    rememberNodesActs _ = RNil

instance (RememberNodesActs' h ys xs', RContains ys t,  Ord h) => RememberNodesActs' h ys (t ': xs') where
    rememberNodesActs var = Const (rememberNodesSingleAct @t var) :& rememberNodesActs var

rememberNodesSingleAct :: forall x xs h . (Ord h, RContains xs x) => TVar (AVLServerState h xs) -> Set h -> STM ()
rememberNodesSingleAct var xs = modifyTVar' var appendToOneSet
  where
    appendToOneSet st@AMS{..} =
      let v' = mappend xs (getConst (rget @x amsVisited))
          newVisited = rput @x (Const v') amsVisited
      in st { amsVisited = newVisited }
