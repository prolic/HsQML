{-# LANGUAGE DeriveDataTypeable, TypeFamilies #-}

module Main where

import Graphics.QML.Test.Framework
import Graphics.QML.Test.Harness
import Graphics.QML.Test.SimpleTest
import Graphics.QML.Test.SignalTest
import Graphics.QML.Test.MixedTest
import Data.Proxy
import System.Exit

main :: IO ()
main = do
    rs <- sequence [
        checkProperty $ TestType (Proxy :: Proxy SimpleMethods),
        checkProperty $ TestType (Proxy :: Proxy SimpleProperties),
        checkProperty $ TestType (Proxy :: Proxy SignalTest1),
        checkProperty $ TestType (Proxy :: Proxy ObjectA)]
    if and rs
    then exitSuccess
    else exitFailure
