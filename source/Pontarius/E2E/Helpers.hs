{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleContexts #-}
module Pontarius.E2E.Helpers where
import           Control.Applicative (Applicative, (<$>), (<*>), pure)
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Error
import           Control.Monad.Identity
import           Crypto.Number.ModArithmetic as Mod
import qualified Crypto.PubKey.DSA as DSA
import qualified Crypto.Random as CRandom
import           Data.Bits (shiftR)
import qualified Data.ByteString as BS
import           Data.Byteable (constEqBytes)
import           Pontarius.E2E.Monad
import           Pontarius.E2E.Serialize
import           Pontarius.E2E.Types

(=~=) :: BS.ByteString -> BS.ByteString -> Bool
(=~=) = constEqBytes

prime :: MonadReader E2EGlobals m => m Integer
prime = parameter paramDHPrime

gen :: MonadReader E2EGlobals m => m Integer
gen = parameter paramDHGenerator

infixr 8 ^.
(^.) :: (Applicative f, MonadReader E2EGlobals f) =>
        f Integer -> f Integer -> f Integer
b ^. e = do Mod.exponantiation_rtl_binary <$> b <*> e <*> prime

infixr 7 *.
(*.) :: (Applicative f, MonadReader E2EGlobals f) =>
        f Integer -> f Integer -> f Integer
x *. y = mulmod <$> x <*> y <*> prime
  where
    mulmod x' y' p = (x' * y') `mod` p

infixl 7 /.
-- | modular division by prime
(/.) :: (Show (m Integer), Applicative m, MonadReader E2EGlobals m) =>
        m Integer -> m Integer -> m Integer
x /. y =  do
    mbi <- Mod.inverse <$> y <*> prime
    case mbi of
        Nothing -> error $ "could not invert " ++ show y
        Just y' -> x *. pure y'


-- | Encrypt a ByteString. The IV is padded with 0s to the required length
encCtr :: MonadReader E2EGlobals m =>
          BS.ByteString -> BS.ByteString -> BS.ByteString -> m BS.ByteString
encCtr key ivHi pl = do
    ebs <- parameter paramEncryptionBlockSize
    let iv = ivHi `BS.append` BS.replicate (ebs - BS.length ivHi) 0
    ectr <- parameter paramEncrypt
    return $ ectr iv key pl

decCtr :: MonadReader E2EGlobals m =>
          BS.ByteString -> BS.ByteString -> BS.ByteString -> m BS.ByteString
decCtr = encCtr

encCtrZero :: MonadReader E2EGlobals m =>
              BS.ByteString -> BS.ByteString -> m BS.ByteString
encCtrZero key pl = encCtr BS.empty key pl

decCtrZero :: MonadReader E2EGlobals m =>
     BS.ByteString -> BS.ByteString -> m BS.ByteString
decCtrZero = encCtrZero

hash :: MonadReader E2EGlobals m => BS.ByteString -> m BS.ByteString
hash pl = do
    h <- parameter paramHash
    return $ h pl


mac :: MonadReader E2EGlobals m =>
       BS.ByteString -> BS.ByteString -> m BS.ByteString
mac key pl = do
    m <- parameter paramMac
    return $ m key pl

mkKey :: (MonadReader E2EGlobals m, CRandom.CPRG g, MonadRandom g m) =>
     m BS.ByteString
mkKey = getBytes =<< parameter paramEncryptionBlockSize

putAuthState :: MonadState E2EState m => AuthState -> m ()
putAuthState as = modify $ \s -> s{authState = as }

putMsgState :: MonadState E2EState m => MsgState -> m ()
putMsgState ms = modify $ \s -> s{msgState = ms }

makeDHSharedSecret :: Integer -> Integer -> E2E g Integer
makeDHSharedSecret private public = do
    p <- prime
    return $ Mod.exponantiation_rtl_binary public private p

parameter :: MonadReader E2EGlobals m => (E2EParameters -> a) -> m a
parameter = asks . (. parameters)

doHash :: MonadReader E2EGlobals m => BS.ByteString -> m BS.ByteString
doHash pl = do
    h <- parameter paramHash
    return $ h pl

-- sign :: CRandom.CPRG g => BS.ByteString -> E2E g DSA.Signature
sign :: (MonadReader E2EGlobals m, CRandom.CPRG g, MonadRandom g m) =>
        BS.ByteString -> m DSA.Signature
sign x = do
   (_, privKey) <- asks dsaKeyPair
   withRandGen $ \g -> DSA.sign g privKey id x


makeDHKeyPair :: (Applicative m, MonadReader E2EGlobals m, CRandom.CPRG g,
                  MonadRandom g m) =>
                 m DHKeyPair
makeDHKeyPair =  do
    ks <- parameter paramDHKeySizeBits
    x <- randomIntegerBits (fromIntegral ks)
    gx <- gen ^. (pure x)
    return $ DHKeyPair gx x


-- randomIntegerBytes :: Int ->Otr Integer
randomIntegerBits :: (CRandom.CPRG g, MonadRandom g m)
                   => Int -> m Integer
randomIntegerBits b = ((`shiftR` ((8 - b) `mod` 8)) . rollInteger . BS.unpack)
                         `liftM` getBytes ((b+7) `div` 8)

protocolGuard :: MonadError E2EError m => ProtocolError -> String -> Bool -> m ()
protocolGuard e s p = unless p . throwError $ ProtocolError e s

protocolGuard' :: MonadError E2EError m => ProtocolError -> Bool -> m ()
protocolGuard' e p = protocolGuard e "" p

newState :: CRandom.CPRG g => ReaderT E2EGlobals (RandT g Identity) E2EState
newState = do
    opk <- makeDHKeyPair
    ock <- makeDHKeyPair
    ndh <- makeDHKeyPair
    return E2EState{ ourPreviousKey   = opk
                   , ourCurrentKey    = ock
                   , ourKeyID         = 1
                   , theirPublicKey   = Nothing
                   , theirCurrentKey  = Nothing
                   , mostRecentKey    = 2
                   , nextDH           = ndh
                   , theirPreviousKey = Nothing
                   , theirKeyID       = 0
                   , authState        = AuthStateNone
                   , msgState         = MsgStatePlaintext
                   , counter          = 1
                   , ssid             = Nothing
                   , verified         = False
                   , smpState         = Nothing
                   }