{-# LANGUAGE DataKinds           #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snowdrop.Dba.AVLp.Actions
       ( AVLChgAccum
       , avlServerDbActions
       , avlClientDbActions
       , RememberNodesActs' (..)
       , RememberNodesActs
       ) where

import           Data.Vinyl (RecMapMethod(..), RecApplicative, rget, rpure, rput)
import           Universum

import qualified Data.Tree.AVL as AVL

import           Data.Default (Default (def))
import qualified Data.Map.Strict as M
import           Data.Vinyl (Rec (..))
import           Data.Vinyl.Recursive (rmap)

import           Snowdrop.Core (ChgAccum, Undo)
import           Snowdrop.Dba.AVLp.Accum (AVLChgAccum (..), AVLChgAccums, RootHashes, computeUndo,
                                          iter, modAccum, modAccumU, query)
import           Snowdrop.Dba.AVLp.Avl (AvlHashable, AllAvlEntries, AvlProof (..), AvlProofs,
                                        AvlUndo, IsAvlEntry, RootHash (..), RootHashComp (..),
                                        avlRootHash, mkAVL, saveAVL)
import           Snowdrop.Dba.AVLp.Constraints (AvlHashC)
import           Snowdrop.Dba.AVLp.State (AVLCache (..), AVLCacheT, AVLPureStorage (..),
                                          AVLServerState (..), ClientTempState, RetrieveF,
                                          RetrieveImpl, clientModeToTempSt, runAVLCacheT)
import           Snowdrop.Dba.Base (ClientMode (..), DbAccessActions (..), DbAccessActionsM (..),
                                    DbAccessActionsU (..), DbApplyProof, DbComponents,
                                    DbModifyActions (..), RememberForProof (..))
import           Snowdrop.Hetero (HKey, HVal, RContains)
import           Snowdrop.Util (NewestFirst)


ignoreNodesActs :: RecApplicative xs => Rec (Const (Set h -> STM ())) xs
ignoreNodesActs = rpure (Const (\_ -> pure ()))

avlClientDbActions
    :: forall conf h xs .
    ( AllAvlEntries h xs
    , AvlHashable h
    , ChgAccum conf ~ AVLChgAccums h xs
    , DbApplyProof conf ~ ()
    , RecApplicative xs
    , RecMapMethod (AvlHashC h) (AVLChgAccum h) xs
    , RetrieveImpl (ReaderT (ClientTempState h xs STM) STM) h
    , Undo conf ~ AvlUndo h xs
    , xs ~ DbComponents conf
    )
    => RetrieveF h STM
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
        writeTVar var $ rmapMethod @(AvlHashC h) (RootHashComp . avlRootHash . acaMap) accums
    apply _ Nothing = pure ()

withProjUndo :: (MonadThrow m, Applicative f) => (NewestFirst [] undo -> a) -> NewestFirst [] undo -> m (f a)
withProjUndo action = pure . pure . action

avlServerDbActions
    :: forall conf h xs .
    ( AllAvlEntries h xs
    , AvlHashable h
    , ChgAccum conf ~ AVLChgAccums h xs
    , DbApplyProof conf ~ AvlProofs h xs
    , RecApplicative xs
    , RecMapMethod (AvlHashC h) (AVLChgAccum h) xs
    , RememberNodesActs h xs
    , Undo conf ~ AvlUndo h xs
    , xs ~ DbComponents  conf
    )
    => AVLServerState h xs
    -> STM ( RememberForProof -> DbModifyActions conf STM
            -- `DbModifyActions` provided by `RememberForProof` object
            -- (`RememberForProof False` for disabling recording for queries performed)
          , RetrieveF h STM
            -- Function to retrieve data from server state internal AVL storage
          )
avlServerDbActions = fmap mkActions . newTVar
  where
    retrieveHash var h = M.lookup h . unAVLPureStorage . amsState <$> readTVar var
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

    apply :: RecApplicative xs
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
        :: RecApplicative xs
        => TVar (AVLServerState h xs)
        -> Rec (AVLChgAccum h) xs
        -> STM (AVLServerState h xs)
    applyDo var accums = do
        s <- readTVar var
        (roots, accCache) <- saveAVLs (amsState s) accums
        let newState = AMS {
              amsRootHashes = roots
            , amsState = AVLPureStorage $ unAVLCache accCache <> unAVLPureStorage (amsState s)
            , amsVisited = rpure (Const mempty)
            }
        writeTVar var newState $> s

    saveAVLs :: AllAvlEntries h rs => AVLPureStorage h -> Rec (AVLChgAccum h) rs -> STM (RootHashes h rs, AVLCache h)
    saveAVLs _ RNil = pure (RNil, def)
    saveAVLs storage (AVLChgAccum accAvl acc _ :& accums) = do
        (h, acc') <- runAVLCacheT (saveAVL accAvl) acc storage
        (restRoots, restAcc) <- saveAVLs storage accums
        pure (RootHashComp h :& restRoots, AVLCache $ unAVLCache acc' <> unAVLCache restAcc)

computeProofAll
    :: (AllAvlEntries h xs, AvlHashable h)
    => RootHashes h xs
    -> Rec (AVLChgAccum h) xs
    -> Rec (Const (Set h)) xs
    -> AVLCacheT h (ReaderT (AVLPureStorage h) STM) (AvlProofs h xs)
computeProofAll RNil RNil RNil = pure RNil
computeProofAll (RootHashComp rootH :& roots) (AVLChgAccum _ _ accTouched :& accums) (req :& reqs) = do
    proof <- AvlProof <$> computeProof rootH accTouched req
    (proof :&) <$> computeProofAll roots accums reqs

computeProof
    :: forall t h . (IsAvlEntry h t, AvlHashable h)
    => RootHash h
    -> Set h
    -> Const (Set h) t
    -> AVLCacheT h (ReaderT (AVLPureStorage h) STM) (AVL.Proof h (HKey t) (HVal t))
computeProof (mkAVL -> oldAvl) accTouched (getConst -> requested) =
        AVL.prune (accTouched <> requested) $ oldAvl

-- Build a record where each element is an effectful action which appends set of
-- hashes to a set which belongs to a given record component
type RememberNodesActs h xs = RememberNodesActs' h xs xs

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
      let v :: Set h = mappend xs (getConst (rget @x amsVisited))
          newVisited = rput @x (Const v) amsVisited
      in st { amsVisited = newVisited }
