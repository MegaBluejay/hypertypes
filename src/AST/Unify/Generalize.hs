{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, TypeFamilies, ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, LambdaCase, InstanceSigs #-}
{-# LANGUAGE RankNTypes, TupleSections #-}

module AST.Unify.Generalize
    ( Generalized(..), _Generalized
    , generalize, monomorphic, instantiate
    , -- TODO: should these not be exported? (Internals)
      instantiateWith
    , GTerm(..), _GMono, _GPoly, _GBody
    ) where

import           Algebra.Lattice (JoinSemiLattice(..))
import           Algebra.PartialOrd (PartialOrd(..))
import           AST
import           AST.Class.Unify (Unify(..), UVar)
import           AST.Unify (newTerm, semiPruneLookup)
import           AST.Unify.Binding (Binding(..))
import           AST.Unify.Constraints (TypeConstraints(..), MonadScopeConstraints(..))
import           AST.Unify.Term (UTerm(..), uBody)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.Writer (WriterT(..), tell)
import           Data.Constraint (withDict)
import           Data.Monoid (All(..))
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

data GTerm v ast
    = GMono (v ast)
    | GPoly (v ast)
    | GBody (Tie ast (GTerm v))
Lens.makePrisms ''GTerm
makeChildren ''GTerm

newtype Generalized ast v = Generalized (Tree (GTerm (RunKnot v)) ast)
Lens.makePrisms ''Generalized

instance Children ast => Children (Generalized ast) where
    type ChildrenConstraint (Generalized ast) cls = Recursive cls ast
    children ::
        forall f constraint n m.
        (Applicative f, Recursive constraint ast) =>
        Proxy constraint ->
        (forall child. constraint child => Tree n child -> f (Tree m child)) ->
        Tree (Generalized ast) n -> f (Tree (Generalized ast) m)
    children p f (Generalized g) =
        withDict (recursive :: RecursiveDict constraint ast) $
        case g of
        GMono x -> f x <&> GMono
        GPoly x -> f x <&> GPoly
        GBody x ->
            children (Proxy :: Proxy (Recursive constraint))
            (fmap (^. _Generalized) . children p f . Generalized) x
            <&> GBody
        <&> Generalized

generalize ::
    forall m t.
    Recursive (Unify m) t =>
    Tree (UVar m) t -> m (Tree (Generalized t) (UVar m))
generalize v0 =
    withDict (recursive :: RecursiveDict (Unify m) t) $
    do
        (v1, u) <- semiPruneLookup v0
        c <- scopeConstraints
        case u of
            UUnbound l | l `leq` c ->
                GPoly v1 <$
                -- We set the variable to a skolem,
                -- so additional unifications after generalization
                -- (for example hole resumptions where supported)
                -- cannot unify it with anything.
                bindVar binding v1 (USkolem (generalizeConstraints l))
            USkolem l | l `leq` c -> pure (GPoly v1)
            UTerm t ->
                children p (fmap (^. _Generalized) . generalize) (t ^. uBody)
                <&> onBody
                where
                    onBody b
                        | foldMapChildren p (All . Lens.has _GMono) b ^. Lens._Wrapped = GMono v1
                        | otherwise = GBody b
            _ -> pure (GMono v1)
    <&> Generalized
    where
        p = Proxy :: Proxy (Recursive (Unify m))

monomorphic :: Tree v t -> Tree (Generalized t) v
monomorphic = Generalized . GMono

instantiateWith ::
    forall m t a.
    Recursive (Unify m) t =>
    m a ->
    Tree (Generalized t) (UVar m) ->
    m (Tree (UVar m) t, a)
instantiateWith action (Generalized g) =
    do
        (r, recover) <- runWriterT (go g)
        action <* sequence_ recover <&> (r, )
    where
        go ::
            forall child.
            Recursive (Unify m) child =>
            Tree (GTerm (UVar m)) child -> WriterT [m ()] m (Tree (UVar m) child)
        go =
            withDict (recursive :: RecursiveDict (Unify m) child) $
            \case
            GMono x -> pure x
            GBody x -> children (Proxy :: Proxy (Recursive (Unify m))) go x >>= lift . newTerm
            GPoly x ->
                lookupVar binding x & lift
                >>=
                \case
                USkolem l ->
                    do
                        tell [bindVar binding x (USkolem l)]
                        r <- scopeConstraints <&> (\/ l) >>= newVar binding . UUnbound & lift
                        UInstantiated r & bindVar binding x & lift
                        pure r
                UInstantiated v -> pure v
                _ -> error "unexpected state at instantiate's forall"

instantiate ::
    Recursive (Unify m) t =>
    Tree (Generalized t) (UVar m) -> m (Tree (UVar m) t)
instantiate g = instantiateWith (pure ()) g <&> (^. Lens._1)
