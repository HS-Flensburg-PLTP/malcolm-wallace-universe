module Text.Parse.ByteString
  ( -- * The Parse class is a replacement for the standard Read class.
    --   This particular instance reads from ByteString rather than String.
    -- $parser
    TextParser  -- synonym for Text.ParserCombinators.Poly.ByteString
  , Parse(..)   -- instances: (), (a,b), (a,b,c), Maybe a, Either a, [a],
                --            Int, Integer, Float, Double, Char, Bool
  , parseByRead -- :: Read a => String -> TextParser a
  , readByParse -- :: TextParser a -> ReadS a
  , readsPrecByParsePrec -- :: (Int->TextParser a) -> Int -> ReadS a
    -- ** Combinators specific to bytestring input, lexed haskell-style
  , word        -- :: TextParser String
  , isWord      -- :: String -> TextParser ()
  , literal     -- :: String -> TextParser ()
  , optionalParens      -- :: TextParser a -> TextParser a
  , parens      -- :: Bool -> TextParser a -> TextParser a
  , field       -- :: Parse a => String -> TextParser a
  , constructors-- :: [(String,TextParser a)] -> TextParser a
  , enumeration -- :: Show a => String -> [a] -> TextParser a
    -- ** Parsers for literal numerics and characters
  , parseSigned
  , parseInt
  , parseDec
  , parseOct
  , parseHex
  , parseUnsignedInteger
  , parseFloat
  , parseLitChar
  , parseLitChar'
    -- ** Re-export all the more general combinators from Poly too
  , module Text.ParserCombinators.Poly.ByteStringChar
    -- ** ByteStrings and Strings as whole entities
  , allAsByteString
  , allAsString
  ) where

import Data.Char as Char (isUpper,isDigit,isOctDigit,isHexDigit,digitToInt
                         ,isSpace,isAlpha,isAlphaNum,ord,chr,toLower)
import Data.List (intersperse)
import Data.Ratio
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.ByteString.Lazy.Char8 (ByteString)
import Text.ParserCombinators.Poly.ByteStringChar

------------------------------------------------------------------------
-- $parser
-- The Parse class is a replacement for the standard Read class.  It is a
-- specialisation of the (poly) Parser monad for ByteString input.
-- There are instances defined for all Prelude types.
-- For user-defined types, you can write your own instance, or use
-- DrIFT to generate them automatically, e.g. {-! derive : Parse !-}

-- | A synonym for a ByteString Parser, i.e. bytestring input (no state)
type TextParser a = Parser a

-- | The class @Parse@ is a replacement for @Read@, operating over String input.
--   Essentially, it permits better error messages for why something failed to
--   parse.  It is rather important that @parse@ can read back exactly what
--   is generated by the corresponding instance of @show@.  To apply a parser
--   to some text, use @runParser@.
class Parse a where
    -- | A straightforward parser for an item.  (A minimal definition of
    --   a class instance requires either |parse| or |parsePrec|.  In general,
    --   for a type that never needs parens, you should define |parse|, but
    --   for a type that _may_ need parens, you should define |parsePrec|.)
    parse     :: TextParser a
    parse       = parsePrec 0
    -- | A straightforward parser for an item, given the precedence of
    --   any surrounding expression.  (Precedence determines whether
    --   parentheses are mandatory or optional.)
    parsePrec :: Int -> TextParser a
    parsePrec _ = optionalParens parse
    -- | Parsing a list of items by default accepts the [] and comma syntax,
    --   except when the list is really a character string using \"\".
    parseList :: TextParser [a] -- only to distinguish [] and ""
    parseList  = do { isWord "[]"; return [] }
                   `onFail`
                 do { isWord "["; isWord "]"; return [] }
                   `onFail`
                 bracketSep (isWord "[") (isWord ",") (isWord "]")
                            (optionalParens parse)
                   `adjustErr` ("Expected a list, but\n"++)

-- | If there already exists a Read instance for a type, then we can make
--   a Parser for it, but with only poor error-reporting.  The string argument
--   is the expected type or value (for error-reporting only).  Use of this
--   wrapper function is NOT recommended with ByteString, because there
--   is a lot of inefficiency in repeated conversions to/from String.
parseByRead :: Read a => String -> TextParser a
parseByRead name =
    P (\s-> case reads (BS.unpack s) of
                []       -> Failure s ("no parse, expected a "++name)
                [(a,s')] -> Success (BS.pack s') a
                _        -> Failure s ("ambiguous parse, expected a "++name)
      )

-- | If you have a TextParser for a type, you can easily make it into
--   a Read instance, by throwing away any error messages.  Use of this
--   wrapper function is NOT recommended with ByteString, because there
--   is a lot of inefficiency in conversions to/from String.
readByParse :: TextParser a -> ReadS a
readByParse p = \inp->
    case runParser p (BS.pack inp) of
        (Left err,  rest) -> []
        (Right val, rest) -> [(val, BS.unpack rest)]

-- | If you have a TextParser for a type, you can easily make it into
--   a Read instance, by throwing away any error messages.  Use of this
--   wrapper function is NOT recommended with ByteString, because there
--   is a lot of inefficiency in conversions to/from String.
readsPrecByParsePrec :: (Int -> TextParser a) -> Int -> ReadS a
readsPrecByParsePrec p = \prec inp->
    case runParser (p prec) (BS.pack inp) of
        (Left err,  rest) -> []
        (Right val, rest) -> [(val, BS.unpack rest)]


-- | One lexical chunk (Haskell-style lexing).
word :: TextParser String
{-
word = P (\s-> case lex (BS.unpack s) of
                   []         -> Failure s  ("no input? (impossible)")
                   [("","")]  -> Failure s ("no input?")
                   [("",_)]   -> Failure s  ("lexing failed?")
                   ((x,_):_)  -> Success (BS.drop (fromIntegral (length x)) s) x
         )
-}
word = P (p . BS.dropWhile isSpace)
  where
    p s | BS.null s = Failure BS.empty "end of input"
        | otherwise =
      case (BS.head s, BS.tail s) of
        ('\'',t) -> let (P lit) = parseLitChar' in fmap show (lit s)
        ('\"',t) -> let (str,rest) = BS.span (not . (`elem` "\\\"")) t
                    in litString ('\"': BS.unpack str) rest
        ('0',s) -> case BS.uncons s of
                     Just ('x',r) -> Success t ("0x"++BS.unpack ds)
                                            where (ds,t) = BS.span isHexDigit r
                     Just ('X',r) -> Success t ("0X"++BS.unpack ds)
                                            where (ds,t) = BS.span isHexDigit r
                     Just ('o',r) -> Success t ("0o"++BS.unpack ds)
                                            where (ds,t) = BS.span isOctDigit r
                     Just ('O',r) -> Success t ("0O"++BS.unpack ds)
                                            where (ds,t) = BS.span isOctDigit r
                     _ -> lexFracExp ('0': BS.unpack ds) t
                                            where (ds,t) = BS.span isDigit s
        (c,s) | isIdInit c -> let (nam,t) = BS.span isIdChar s in
                                                   Success t (c: BS.unpack nam)
              | isDigit  c -> let (ds,t)  = BS.span isDigit s in
                                                 lexFracExp (c: BS.unpack ds) t
              | isSingle c -> Success s (c:[])
              | isSym    c -> let (sym,t) = BS.span isSym s in
                                                   Success t (c: BS.unpack sym)
              | otherwise  -> Failure (BS.cons c s) ("Bad character: "++show c)

    isSingle c  =  c `elem` ",;()[]{}`"
    isSym    c  =  c `elem` "!@#$%&*+./<=>?\\^|:-~"
    isIdInit c  =  isAlpha c || c == '_'
    isIdChar c  =  isAlphaNum c || c `elem` "_'"

    lexFracExp acc s = case BS.uncons s of
                           Just ('.',s') ->
                               case BS.uncons s' of
                                   Just (d,s'') | isDigit d ->
                                        let (ds,t) = BS.span isDigit s'' in
                                        lexExp (acc++'.':d: BS.unpack ds) t
                                   _ -> lexExp acc s'
                           _ -> lexExp acc s

    lexExp acc s = case BS.uncons s of
        Just (e,s') | e `elem` "eE" ->
                    case BS.uncons s' of
                        Just (sign,dt)
                            | sign `elem` "+-" ->
                                  case BS.uncons dt of
                                      Just (d,t) | isDigit d ->
                                          let (ds,u) = BS.span isDigit t in
                                          Success u (acc++'e': sign: d:
                                                     BS.unpack ds)
                            | isDigit sign ->
                                  let (ds,u) = BS.span isDigit dt in
                                  Success u (acc++'e': sign: BS.unpack ds)
                        _ -> Failure s' ("missing +/-/digit "
                                        ++"after e in float literal: "
                                        ++show (acc++'e':"..."))
        _ -> Success s acc

    litString acc s = case BS.uncons s of
        Nothing       -> Failure (BS.empty)
                                 ("end of input in string literal "++acc)
        Just ('\"',r) -> Success r (acc++"\"")
        Just ('\\',r) -> let (P lit) = parseLitChar
                         in case lit s of
                              Failure a b  -> Failure a b
                              Success t char ->
                                  let (u,v) = BS.span (`notElem`"\\\"") t
                                  in  litString (acc++[char]++BS.unpack u) v
        Just (_,r)    -> error "Text.Parse.word(litString) - can't happen"


-- | Ensure that the next input word is the given string.  (Note the input
--   is lexed as haskell, so wordbreaks at spaces, symbols, etc.)
isWord :: String -> TextParser String
isWord w = do { w' <- word
              ; if w'==w then return w else fail ("expected "++w++" got "++w')
              }

-- | Ensure that the next input word is the given string.  (No
--   lexing, so mixed spaces, symbols, are accepted.)
literal :: String -> TextParser String
literal w = do { w' <- exactly (length w) next
               ; if w'==w then return w
                          else fail ("expected "++w++" got "++w')
               }

-- | Allow optional nested string parens around an item.
optionalParens :: TextParser a -> TextParser a
optionalParens p = parens False p

-- | Allow nested parens around an item (one set required when Bool is True).
parens :: Bool -> TextParser a -> TextParser a
parens True  p = bracket (isWord "(") (isWord ")") (parens False p)
parens False p = parens True p `onFail` p

-- | Deal with named field syntax.  The string argument is the field name,
--   and the parser returns the value of the field.
field :: Parse a => String -> TextParser a
field name = do { isWord name; commit $ do { isWord "="; parse } }

-- | Parse one of a bunch of alternative constructors.  In the list argument,
--   the first element of the pair is the constructor name, and
--   the second is the parser for the rest of the value.  The first matching
--   parse is returned.
constructors :: [(String,TextParser a)] -> TextParser a
constructors cs = oneOf' (map cons cs)
    where cons (name,p) =
               ( name
               , do { isWord name
                    ; p `adjustErrBad` (("got constructor, but within "
                                        ++name++",\n")++)
                    }
               )

-- | Parse one of the given nullary constructors (an enumeration).
--   The string argument is the name of the type, and the list argument
--   should contain all of the possible enumeration values.
enumeration :: (Show a) => String -> [a] -> TextParser a
enumeration typ cs = oneOf (map (\c-> do { isWord (show c); return c }) cs)
                         `adjustErr`
                     (++("\n  expected "++typ++" value ("++e++")"))
    where e = concat (intersperse ", " (map show (init cs)))
              ++ ", or " ++ show (last cs)

------------------------------------------------------------------------
-- Instances for all the Standard Prelude types.

-- Numeric types

-- | For any numeric parser, permit a negation sign in front of it.
parseSigned :: Real a => TextParser a -> TextParser a
parseSigned p = do '-' <- next; commit (fmap negate p)
                `onFail`
                do p

-- | Parse any (unsigned) Integral numeric literal.
--   Needs a base, radix, isDigit predicate,
--   and digitToInt converter, appropriate to the result type.
parseInt :: (Integral a) => String ->
                            a -> (Char -> Bool) -> (Char -> Int) ->
                            TextParser a
parseInt base radix isDigit digitToInt =
                 do cs <- many1 (satisfy isDigit)
                    return (foldl1 (\n d-> n*radix+d)
                                   (map (fromIntegral.digitToInt) cs))
                 `adjustErr` (++("\nexpected one or more "++base++" digits"))

-- | Parse a decimal, octal, or hexadecimal (unsigned) Integral numeric literal.
parseDec, parseOct, parseHex :: (Integral a) => TextParser a
parseDec = parseInt "decimal" 10 Char.isDigit    Char.digitToInt
parseOct = parseInt "octal"    8 Char.isOctDigit Char.digitToInt
parseHex = parseInt "hex"     16 Char.isHexDigit Char.digitToInt

-- | parseUnsignedInteger uses the underlying ByteString readInteger, so
--   will be a lot faster than the generic character-by-character parseInt.
parseUnsignedInteger :: TextParser Integer
parseUnsignedInteger = P (\bs -> case BS.uncons bs of
                                 Just (c, _)
                                  | Char.isDigit c ->
                                     case BS.readInteger bs of
                                     Just (i, bs') -> Success bs' i
                                     Nothing -> error "XXX Can't happen"
                                 _ -> Failure bs "parsing Integer: not a digit")
               `adjustErr` (++("\nexpected one or more decimal digits"))

-- | Parse any (unsigned) Floating numeric literal, e.g. Float or Double.
parseFloat :: (RealFrac a) => TextParser a
parseFloat = do ds   <- many1Satisfy isDigit
                frac <- (do '.' <- next
                            manySatisfy isDigit
                              `adjustErrBad` (++"expected digit after .")
                         `onFail` return BS.empty )
                exp  <- exponent `onFail` return 0
                ( return . fromRational . (* (10^^(exp - BS.length frac)))
                  . (% 1) .  (\ (Right x) -> x) . fst
                  . runParser parseDec ) (ds `BS.append` frac)
             `onFail`
             do w <- manySatisfy isAlpha
                case map toLower (BS.unpack w) of
                  "nan"      -> return (0/0)
                  "infinity" -> return (1/0)
                  _          -> fail "expected a floating point number"
  where exponent = do 'e' <- fmap toLower next
                      commit (do '+' <- next; parseDec
                              `onFail`
                              parseSigned parseDec )

-- | Parse a Haskell character literal, including surrounding single quotes.
parseLitChar' :: TextParser Char
parseLitChar' = do '\'' <- next `adjustErr` (++"expected a literal char")
                   char <- parseLitChar
                   '\'' <- next `adjustErrBad` (++"literal char has no final '")
                   return char

-- | Parse a Haskell character literal, excluding surrounding single quotes.
parseLitChar :: TextParser Char
parseLitChar = do c <- next
                  char <- case c of
                            '\\' -> next >>= escape
                            '\'' -> fail "expected a literal char, got ''"
                            _    -> return c
                  return char

  where
    escape 'a'  = return '\a'
    escape 'b'  = return '\b'
    escape 'f'  = return '\f'
    escape 'n'  = return '\n'
    escape 'r'  = return '\r'
    escape 't'  = return '\t'
    escape 'v'  = return '\v'
    escape '\\' = return '\\'
    escape '"'  = return '"'
    escape '\'' = return '\''
    escape '^'  = do ctrl <- next
                     if ctrl >= '@' && ctrl <= '_'
                       then return (chr (ord ctrl - ord '@'))
                       else fail ("literal char ctrl-escape malformed: \\^"
                                   ++[ctrl])
    escape d | isDigit d
                = fmap chr $  (reparse (BS.pack [d]) >> parseDec)
    escape 'o'  = fmap chr $  parseOct
    escape 'x'  = fmap chr $  parseHex
    escape c | isUpper c
                = mnemonic c
    escape c    = fail ("unrecognised escape sequence in literal char: \\"++[c])

    mnemonic 'A' = do 'C' <- next; 'K' <- next; return '\ACK'
                   `wrap` "'\\ACK'"
    mnemonic 'B' = do 'E' <- next; 'L' <- next; return '\BEL'
                   `onFail`
                   do 'S' <- next; return '\BS'
                   `wrap` "'\\BEL' or '\\BS'"
    mnemonic 'C' = do 'R' <- next; return '\CR'
                   `onFail`
                   do 'A' <- next; 'N' <- next; return '\CAN'
                   `wrap` "'\\CR' or '\\CAN'"
    mnemonic 'D' = do 'E' <- next; 'L' <- next; return '\DEL'
                   `onFail`
                   do 'L' <- next; 'E' <- next; return '\DLE'
                   `onFail`
                   do 'C' <- next; ( do '1' <- next; return '\DC1'
                                     `onFail`
                                     do '2' <- next; return '\DC2'
                                     `onFail`
                                     do '3' <- next; return '\DC3'
                                     `onFail`
                                     do '4' <- next; return '\DC4' )
                   `wrap` "'\\DEL' or '\\DLE' or '\\DC[1..4]'"
    mnemonic 'E' = do 'T' <- next; 'X' <- next; return '\ETX'
                   `onFail`
                   do 'O' <- next; 'T' <- next; return '\EOT'
                   `onFail`
                   do 'N' <- next; 'Q' <- next; return '\ENQ'
                   `onFail`
                   do 'T' <- next; 'B' <- next; return '\ETB'
                   `onFail`
                   do 'M' <- next; return '\EM'
                   `onFail`
                   do 'S' <- next; 'C' <- next; return '\ESC'
                   `wrap` "one of '\\ETX' '\\EOT' '\\ENQ' '\\ETB' '\\EM' or '\\ESC'"
    mnemonic 'F' = do 'F' <- next; return '\FF'
                   `onFail`
                   do 'S' <- next; return '\FS'
                   `wrap` "'\\FF' or '\\FS'"
    mnemonic 'G' = do 'S' <- next; return '\GS'
                   `wrap` "'\\GS'"
    mnemonic 'H' = do 'T' <- next; return '\HT'
                   `wrap` "'\\HT'"
    mnemonic 'L' = do 'F' <- next; return '\LF'
                   `wrap` "'\\LF'"
    mnemonic 'N' = do 'U' <- next; 'L' <- next; return '\NUL'
                   `onFail`
                   do 'A' <- next; 'K' <- next; return '\NAK'
                   `wrap` "'\\NUL' or '\\NAK'"
    mnemonic 'R' = do 'S' <- next; return '\RS'
                   `wrap` "'\\RS'"
    mnemonic 'S' = do 'O' <- next; 'H' <- next; return '\SOH'
                   `onFail`
                   do 'O' <- next; return '\SO'
                   `onFail`
                   do 'T' <- next; 'X' <- next; return '\STX'
                   `onFail`
                   do 'I' <- next; return '\SI'
                   `onFail`
                   do 'Y' <- next; 'N' <- next; return '\SYN'
                   `onFail`
                   do 'U' <- next; 'B' <- next; return '\SUB'
                   `onFail`
                   do 'P' <- next; return '\SP'
                   `wrap` "'\\SOH' '\\SO' '\\STX' '\\SI' '\\SYN' '\\SUB' or '\\SP'"
    mnemonic 'U' = do 'S' <- next; return '\US'
                   `wrap` "'\\US'"
    mnemonic 'V' = do 'T' <- next; return '\VT'
                   `wrap` "'\\VT'"
    wrap p s = p `onFail` fail ("expected literal char "++s)

-- Basic types
instance Parse Int where
    parse = fmap fromInteger $  -- convert from Integer, deals with minInt
              do manySatisfy isSpace; parseSigned parseUnsignedInteger
instance Parse Integer where
    parse = do manySatisfy isSpace; parseSigned parseUnsignedInteger
instance Parse Float where
    parse = do manySatisfy isSpace; parseSigned parseFloat
instance Parse Double where
    parse = do manySatisfy isSpace; parseSigned parseFloat
instance Parse Char where
    parse = do manySatisfy isSpace; parseLitChar'
        -- not totally correct for strings...
    parseList = do { w <- word; if head w == '"' then return (init (tail w))
                                else fail "not a string" }

instance Parse Bool where
    parse = enumeration "Bool" [False,True]

instance Parse Ordering where
    parse = enumeration "Ordering" [LT,EQ,GT]

-- Structural types
instance Parse () where
    parse = P (p . BS.uncons)
      where p Nothing         = Failure BS.empty "no input: expected a ()"
            p (Just ('(',cs)) = case BS.uncons (BS.dropWhile isSpace cs) of
                                Just (')',s) -> Success s ()
                                _            -> Failure cs "Expected ) after ("
            p (Just (c,cs))   | isSpace c = p (BS.uncons cs)
                              | otherwise = Failure (BS.cons c cs)
                                                ("Expected a (), got "++show c)

instance (Parse a, Parse b) => Parse (a,b) where
    parse = do{ isWord "(" `adjustErr` ("Opening a 2-tuple\n"++)
              ; x <- parse `adjustErr` ("In 1st item of a 2-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating a 2-tuple\n"++)
              ; y <- parse `adjustErr` ("In 2nd item of a 2-tuple\n"++)
              ; isWord ")" `adjustErr` ("Closing a 2-tuple\n"++)
              ; return (x,y) }

instance (Parse a, Parse b, Parse c) => Parse (a,b,c) where
    parse = do{ isWord "(" `adjustErr` ("Opening a 3-tuple\n"++)
              ; x <- parse `adjustErr` ("In 1st item of a 3-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating(1) a 3-tuple\n"++)
              ; y <- parse `adjustErr` ("In 2nd item of a 3-tuple\n"++)
              ; isWord "," `adjustErr` ("Separating(2) a 3-tuple\n"++)
              ; z <- parse `adjustErr` ("In 3rd item of a 3-tuple\n"++)
              ; isWord ")" `adjustErr` ("Closing a 3-tuple\n"++)
              ; return (x,y,z) }

instance Parse a => Parse (Maybe a) where
    parsePrec p =
            optionalParens (do { isWord "Nothing"; return Nothing })
            `onFail`
            parens (p>9)   (do { isWord "Just"
                               ; fmap Just $ parsePrec 10
                                     `adjustErrBad` ("but within Just, "++) })
            `adjustErr` (("expected a Maybe (Just or Nothing)\n"++).indent 2)

instance (Parse a, Parse b) => Parse (Either a b) where
    parsePrec p =
            parens (p>9) $
            constructors [ ("Left",  do { fmap Left  $ parsePrec 10 } )
                         , ("Right", do { fmap Right $ parsePrec 10 } )
                         ]

instance Parse a => Parse [a] where
    parse = parseList

------------------------------------------------------------------------
-- ByteStrings as a whole entity.

-- | Simply return the remaining input ByteString.
allAsByteString :: TextParser ByteString
allAsByteString =  P (\bs-> Success BS.empty bs)

-- | Simply return the remaining input as a String.
allAsString     :: TextParser String
allAsString     =  fmap BS.unpack allAsByteString

------------------------------------------------------------------------
