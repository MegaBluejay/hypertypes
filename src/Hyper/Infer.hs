module Hyper.Infer
    ( infer
    , module Hyper.Class.Infer
    , module Hyper.Class.Infer.Env
    , module Hyper.Class.Infer.InferOf
    , module Hyper.Infer.ScopeLevel
    , module Hyper.Infer.Result

    , -- | Exported only for SPECIALIZE pragmas
      inferH
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Data.Constraint (withDict)
import           Data.Proxy (Proxy(..))
import           Hyper
import           Hyper.Class.Infer
import           Hyper.Class.Infer.Env
import           Hyper.Class.Infer.InferOf
import           Hyper.Infer.Result
import           Hyper.Infer.ScopeLevel
import           Hyper.Unify (UVarOf)

import           Prelude.Compat

-- | Perform Hindley-Milner type inference of a term
{-# INLINE infer #-}
infer ::
    forall m t a.
    Infer m t =>
    Tree (Ann a) t ->
    m (Tree (Ann (a :*: InferResult (UVarOf m))) t)
infer (Ann a x) =
    withDict (inferContext (Proxy @m) (Proxy @t)) $
    inferBody (hmap (Proxy @(Infer m) #> inferH) x)
    <&> (\(xI, t) -> Ann (a :*: InferResult t) xI)

{-# INLINE inferH #-}
inferH ::
    Infer m t =>
    Tree (Ann a) t ->
    Tree (InferChild m (Ann (a :*: InferResult (UVarOf m)))) t
inferH c = infer c <&> (\i -> InferredChild i (i ^. hAnn . Lens._2 . _InferResult)) & InferChild
