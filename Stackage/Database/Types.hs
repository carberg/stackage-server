module Stackage.Database.Types
    ( SnapName (..)
    ) where

import ClassyPrelude.Conduit
import Web.PathPieces
import Data.Text.Read (decimal)
import Database.Persist
import Database.Persist.Sql

data SnapName = SNLts !Int !Int
              | SNNightly !Day
    deriving (Eq, Read, Show)
instance PersistField SnapName where
    toPersistValue = toPersistValue . toPathPiece
    fromPersistValue v = do
        t <- fromPersistValue v
        case fromPathPiece t of
            Nothing -> Left $ "Invalid SnapName: " ++ t
            Just x -> return x
instance PersistFieldSql SnapName where
    sqlType = sqlType . fmap toPathPiece
instance PathPiece SnapName where
    toPathPiece (SNLts x y) = concat ["lts-", tshow x, ".", tshow y]
    toPathPiece (SNNightly d) = "nightly-" ++ tshow d

    fromPathPiece t0 =
        nightly <|> lts
      where
        nightly = fmap SNNightly $ stripPrefix "nightly-" t0 >>= readMay
        lts = do
            t1 <- stripPrefix "lts-" t0
            Right (x, t2) <- Just $ decimal t1
            t3 <- stripPrefix "." t2
            Right (y, "") <- Just $ decimal t3
            return $ SNLts x y
