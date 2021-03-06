 {-# LANGUAGE DeriveGeneric #-}
 {-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-| An IPv4 data type
    
    This module provides the IPv4 data type and functions for working
    with it. There are also encoding and decoding functions provided
    in this module, but they should be imported from 
    @Net.IPv4.Text@ and @Net.IPv4.ByteString.Char8@ instead. They are
    defined here so that the 'FromJSON' and 'ToJSON' instances can
    use them.

-}
    
module Net.IPv4 
  ( -- * Types
    IPv4(..)
  , IPv4Range(..)
    -- * Conversion Functions
  , fromOctets
  , fromOctets'
  , toOctets
    -- * Encoding and Decoding Functions
  , fromDotDecimalText
  , fromDotDecimalText'
  , rangeFromDotDecimalText'
  , dotDecimalRangeParser
  , dotDecimalParser
  , toDotDecimalText
  , toDotDecimalBuilder
  , rangeToDotDecimalText
  , rangeToDotDecimalBuilder
  ) where

import qualified Data.Text.Lazy         as LText
import qualified Data.Text.Lazy.Builder as TBuilder
import Data.Text.Lazy.Builder.Int (decimal)
import Data.Monoid ((<>))
import Data.Bits ((.&.),(.|.),shiftR,shiftL,complement)
import Data.Word
import Data.Int
import Data.Hashable
import Data.Aeson (FromJSON(..),ToJSON(..))
import GHC.Generics (Generic)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.Attoparsec.Text as AT
import Net.Internal (attoparsecParseJSON,rightToMaybe)
import Control.Monad
import Data.Text.Internal (Text(..))
import Control.Monad.ST
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8  as BC8
import qualified Data.ByteString        as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import qualified Data.Text.Lazy.Builder as TBuilder
import qualified Data.Text.Array        as TArray

newtype IPv4 = IPv4 { getIPv4 :: Word32 }
  deriving (Eq,Ord,Show,Read,Enum,Bounded,Hashable,Generic)

data IPv4Range = IPv4Range 
  { ipv4RangeBase   :: {-# UNPACK #-} !IPv4
  , ipv4RangeLength :: {-# UNPACK #-} !Int8
  } deriving (Eq,Ord,Show,Read,Generic)

instance Hashable IPv4Range

instance ToJSON IPv4 where
  toJSON addr = Aeson.String (toDotDecimalText addr)

instance FromJSON IPv4 where
  parseJSON = attoparsecParseJSON (dotDecimalParser <* AT.endOfInput)

instance ToJSON IPv4Range where
  toJSON addrRange = Aeson.String (rangeToDotDecimalText addrRange)

instance FromJSON IPv4Range where
  parseJSON (Aeson.String t) = 
    case rangeFromDotDecimalText' t of
      Left err  -> fail err
      Right res -> return res
  parseJSON _ = mzero

-- mask :: Int -> IPv4
-- mask w = IPv4 $ complement $ 0xffffffff `shiftR` w

fromDotDecimalText' :: Text -> Either String IPv4
fromDotDecimalText' t = 
  AT.parseOnly (dotDecimalParser <* AT.endOfInput) t

fromDotDecimalText :: Text -> Maybe IPv4
fromDotDecimalText = rightToMaybe . fromDotDecimalText'

rangeFromDotDecimalText' :: Text -> Either String IPv4Range
rangeFromDotDecimalText' t = 
  AT.parseOnly (dotDecimalRangeParser <* AT.endOfInput) t

rangeFromDotDecimalText :: Text -> Maybe IPv4Range
rangeFromDotDecimalText = rightToMaybe . rangeFromDotDecimalText'

dotDecimalRangeParser :: AT.Parser IPv4Range
dotDecimalRangeParser = IPv4Range
  <$> dotDecimalParser
  <*  AT.char '/'
  <*> (AT.decimal >>= limitSize)
  where
  limitSize i = 
    if i > 32
      then fail "An IP range length must be between 0 and 32"
      else return i

-- | This does not do an endOfInput check because it is
-- reused in the range parser implementation.
dotDecimalParser :: AT.Parser IPv4
dotDecimalParser = fromOctets'
  <$> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  where
  limitSize i = 
    if i > 255 
      then fail "All octets in an ip address must be between 0 and 255"
      else return i

fromOctets :: Word8 -> Word8 -> Word8 -> Word8 -> IPv4
fromOctets a b c d = fromOctets' 
  (fromIntegral a) (fromIntegral b) (fromIntegral c) (fromIntegral d)

-- | This is sort of a misnomer. It takes Word32 to make
--   dotDecimalParser probably perform better.
fromOctets' :: Word32 -> Word32 -> Word32 -> Word32 -> IPv4
fromOctets' a b c d = IPv4 
    ( shiftL a 24
  .|. shiftL b 16
  .|. shiftL c 8
  .|. d
    )

toOctets :: IPv4 -> (Word8,Word8,Word8,Word8)
toOctets (IPv4 w) =
  ( fromIntegral (shiftR w 24)
  , fromIntegral (shiftR w 16)
  , fromIntegral (shiftR w 8)
  , fromIntegral w
  )

toDotDecimalText :: IPv4 -> Text
toDotDecimalText = toTextPreAllocated
{-# INLINE toDotDecimalText #-}

-- It should be possible to write a more efficient version that initially
-- allocates a block of strict text of length 15 and then starts filling 
-- it in.
toDotDecimalBuilder :: IPv4 -> TBuilder.Builder
toDotDecimalBuilder = TBuilder.fromText . toTextPreAllocated
{-# INLINE toDotDecimalBuilder #-}

rangeToDotDecimalText :: IPv4Range -> Text
rangeToDotDecimalText = LText.toStrict . TBuilder.toLazyText . rangeToDotDecimalBuilder

rangeToDotDecimalBuilder :: IPv4Range -> TBuilder.Builder
rangeToDotDecimalBuilder (IPv4Range addr len) = 
  toDotDecimalBuilder addr
  <> TBuilder.singleton '/'
  <> decimal len

toTextPreAllocated :: IPv4 -> Text
toTextPreAllocated (IPv4 w) =
  let w1 = fromIntegral $ 255 .&. shiftR w 24
      w2 = fromIntegral $ 255 .&. shiftR w 16
      w3 = fromIntegral $ 255 .&. shiftR w 8
      w4 = fromIntegral $ 255 .&. w
      dot = 46
      (arr,len) = runST $ do
        marr <- TArray.new 15
        i1 <- putAndCount 0 w1 marr
        let n1 = i1
            n1' = i1 + 1
        TArray.unsafeWrite marr n1 dot
        i2 <- putAndCount n1' w2 marr
        let n2 = i2 + n1'
            n2' = n2 + 1
        TArray.unsafeWrite marr n2 dot
        i3 <- putAndCount n2' w3 marr
        let n3 = i3 + n2'
            n3' = n3 + 1
        TArray.unsafeWrite marr n3 dot
        i4 <- putAndCount n3' w4 marr
        theArr <- TArray.unsafeFreeze marr
        return (theArr,i4 + n3')
  in Text arr 0 len
    
putAndCount :: Int -> Word8 -> TArray.MArray s -> ST s Int
putAndCount pos w marr
  | w < 10 = TArray.unsafeWrite marr pos (i2w w) >> return 1
  | w < 100 = write2 pos w >> return 2
  | otherwise = write3 pos w >> return 3
  where
  write2 off i0 = do
    let i = fromIntegral i0; j = i + i
    TArray.unsafeWrite marr off $ get2 j
    TArray.unsafeWrite marr (off + 1) $ get2 (j + 1)
  write3 off i0 = do
    let i = fromIntegral i0; j = i + i + i
    TArray.unsafeWrite marr off $ get3 j
    TArray.unsafeWrite marr (off + 1) $ get3 (j + 1)
    TArray.unsafeWrite marr (off + 2) $ get3 (j + 2)
  get2 = fromIntegral . ByteString.unsafeIndex twoDigits
  get3 = fromIntegral . ByteString.unsafeIndex threeDigits

zero :: Word16
zero = 48
{-# INLINE zero #-}

i2w :: (Integral a) => a -> Word16
i2w v = zero + fromIntegral v
{-# INLINE i2w #-}

twoDigits :: ByteString
twoDigits = BC8.pack
  "0001020304050607080910111213141516171819\
  \2021222324252627282930313233343536373839\
  \4041424344454647484950515253545556575859\
  \6061626364656667686970717273747576777879\
  \8081828384858687888990919293949596979899"

threeDigits :: ByteString
threeDigits = 
  ByteString.replicate 300 0 <> BC8.pack
  "100101102103104105106107108109110111112\
  \113114115116117118119120121122123124125\
  \126127128129130131132133134135136137138\
  \139140141142143144145146147148149150151\
  \152153154155156157158159160161162163164\
  \165166167168169170171172173174175176177\
  \178179180181182183184185186187188189190\
  \191192193194195196197198199200201202203\
  \204205206207208209210211212213214215216\
  \217218219220221222223224225226227228229\
  \230231232233234235236237238239240241242\
  \243244245246247248249250251252253254255"

