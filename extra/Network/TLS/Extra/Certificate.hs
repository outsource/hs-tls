{-# LANGUAGE OverloadedStrings, CPP #-}
-- |
-- Module      : Network.TLS.Extra.Certificate
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Extra.Certificate
    ( certificateChecks
    , certificateVerifyChain
    , certificateVerifyAgainst
    , certificateSelfSigned
    , certificateVerifyDomain
    , certificateVerifyValidity
    , certificateFingerprint
    ) where

import Control.Applicative ((<$>))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Certificate.X509

-- for signing/verifying certificate
import qualified Crypto.Hash.SHA1 as SHA1
import qualified Crypto.PubKey.HashDescr as HD
import qualified Crypto.PubKey.RSA.PKCS15 as RSA
import qualified Crypto.PubKey.DSA as DSA

import Data.CertificateStore
import Data.Certificate.X509.Cert (oidCommonName)
import Network.TLS (CertificateUsage(..), CertificateRejectReason(..))

import Data.Time.Calendar
import Data.List (find)
import Data.Maybe (fromMaybe)

#if defined(NOCERTVERIFY)
import System.IO (hPutStrLn, stderr, hIsTerminalDevice)
import Control.Monad (when)
#endif

-- | Returns 'CertificateUsageAccept' if all the checks pass, or the first
--   failure.
certificateChecks :: [ [X509] -> IO CertificateUsage ] -> [X509] -> IO CertificateUsage
certificateChecks checks x509s =
    fromMaybe CertificateUsageAccept . find (CertificateUsageAccept /=) <$> mapM ($ x509s) checks

#if defined(NOCERTVERIFY)

# warning "********certificate verify chain doesn't yet work on your platform *************"
# warning "********please consider contributing to the certificate to fix this issue *************"
# warning "********getting trusted system certificate is platform dependant *************"

{- on windows, the trusted certificates are not yet accessible,
 - for now, print a big fat warning (better than nothing) and returns true  -}
certificateVerifyChain_ :: CertificateStore -> [X509] -> IO CertificateUsage
certificateVerifyChain_ _ _ = do
    wvisible <- hIsTerminalDevice stderr
    when wvisible $ do
        hPutStrLn stderr "tls-extra:Network.TLS.Extra.Certificate"
        hPutStrLn stderr "****************** certificate verify chain doesn't yet work on your platform **********************"
        hPutStrLn stderr "please consider contributing to the certificate package to fix this issue"
    return CertificateUsageAccept

#else
certificateVerifyChain_ :: CertificateStore -> [X509] -> IO CertificateUsage
certificateVerifyChain_ _     []     = return $ CertificateUsageReject (CertificateRejectOther "empty chain / no certificates")
certificateVerifyChain_ store (x:xs) =
    -- find a matching certificate that we trust (== installed on the system)
    case findCertificate (certIssuerDN $ x509Cert x) store of
        Just sysx509 -> do
            validChain <- certificateVerifyAgainst x sysx509
            if validChain
                then return CertificateUsageAccept
                else return certificateChainDoesntMatch
        Nothing      ->
            case xs of
                []     -> return $ CertificateUsageReject CertificateRejectUnknownCA
                cert:_ -> do
                    let exts = certExtensions (x509Cert cert)
                    case checkCA exts of
                        Just r  -> return r
                        Nothing -> do
                            validChain <- certificateVerifyAgainst x cert
                            if validChain
                                then certificateVerifyChain_ store xs
                                else return certificateChainDoesntMatch
    where checkCA Nothing   = return $ certificateNotAllowedToSign
          checkCA (Just es) = do
              let kuCanCertSign = case extensionGet es of
                                      Just (ExtKeyUsage l) -> elem KeyUsage_keyCertSign l
                                      Nothing              -> False
              case extensionGet es of
                  Just (ExtBasicConstraints True _)
                                         | kuCanCertSign -> Nothing
                                         | otherwise     -> Just certificateNotAllowedToSign
                  _                                      -> Just certificateNotAllowedToSign
          certificateNotAllowedToSign = CertificateUsageReject $ CertificateRejectOther "certificate is not allowed to sign another certificate"
          certificateChainDoesntMatch = CertificateUsageReject $ CertificateRejectOther "chain doesn't match each other"
#endif

-- | verify a certificates chain using the system certificates available.
--
-- each certificate of the list is verified against the next certificate, until
-- it can be verified against a system certificate (system certificates are assumed as trusted)
--
-- This helper only check that the chain of certificate is valid, which means that each items
-- received are signed by the next one, or by a system certificate. Some extra checks need to
-- be done at the user level so that the certificate chain received make sense in the context.
--
-- for example for HTTP, the user should typically verify the certificate subject match the URL
-- of connection.
--
-- TODO: verify validity, check revocation list if any, add optional user output to know
-- the rejection reason.
certificateVerifyChain :: CertificateStore -> [X509] -> IO CertificateUsage
certificateVerifyChain store = certificateVerifyChain_ store . reorderList
    where
        reorderList []     = []
        reorderList (x:xs) =
            case find (certMatchDN x) xs of
                Nothing    -> x : reorderList xs
                Just found -> x : found : reorderList (filter (/= found) xs)

-- | verify a certificate against another one.
-- the first certificate need to be signed by the second one for this function to succeed.
certificateVerifyAgainst :: X509 -> X509 -> IO Bool
certificateVerifyAgainst ux509@(X509 _ _ _ sigalg sig) (X509 scert _ _ _ _) =
    return $ (verifyF sigalg pk) udata esig
    where
        udata = B.concat $ L.toChunks $ getSigningData ux509
        esig  = B.pack sig
        pk    = certPubKey scert

-- | Is this certificate self signed?
certificateSelfSigned :: X509 -> Bool
certificateSelfSigned x509 = certMatchDN x509 x509

certMatchDN :: X509 -> X509 -> Bool
certMatchDN (X509 testedCert _ _ _ _) (X509 issuerCert _ _ _ _) =
    certSubjectDN issuerCert == certIssuerDN testedCert

verifyF :: SignatureALG -> PubKey -> B.ByteString -> B.ByteString -> Bool

-- md[245]WithRSAEncryption:
--
--   pkcs-1 OBJECT IDENTIFIER ::= { iso(1) member-body(2) US(840) rsadsi(113549) pkcs(1) 1 }
--   rsaEncryption OBJECT IDENTIFIER ::= { pkcs-1 1 }
--   md2WithRSAEncryption OBJECT IDENTIFIER ::= { pkcs-1 2 }
--   md4WithRSAEncryption OBJECT IDENTIFIER ::= { pkcs-1 3 }
--   md5WithRSAEncryption OBJECT IDENTIFIER ::= { pkcs-1 4 }
verifyF (SignatureALG HashMD2 PubKeyALG_RSA) (PubKeyRSA rsak) = RSA.verify HD.hashDescrMD2 rsak
verifyF (SignatureALG HashMD5 PubKeyALG_RSA) (PubKeyRSA rsak) = RSA.verify HD.hashDescrMD5 rsak
verifyF (SignatureALG HashSHA1 PubKeyALG_RSA) (PubKeyRSA rsak) = RSA.verify HD.hashDescrSHA1 rsak
verifyF (SignatureALG HashSHA1 PubKeyALG_DSA) (PubKeyDSA dsak) = dsaSHA1Verify dsak

verifyF _ _ = \_ _ -> False

dsaSHA1Verify pk _ b = DSA.verify SHA1.hash pk asig b
    where asig = (0,0) {- FIXME : need to work out how to get R/S from the bytestring a -}

-- | Verify that the given certificate chain is application to the given fully qualified host name.
certificateVerifyDomain :: String -> [X509] -> CertificateUsage
certificateVerifyDomain _      []                  = CertificateUsageReject (CertificateRejectOther "empty list")
certificateVerifyDomain fqhn (X509 cert _ _ _ _:_) =
    let names = maybe [] ((:[]) . snd) (lookup oidCommonName $ getDistinguishedElements $ certSubjectDN cert)
             ++ maybe [] (maybe [] toAltName . extensionGet) (certExtensions cert) in
    orUsage $ map (matchDomain . splitDot) names
    where
        orUsage [] = rejectMisc "FQDN do not match this certificate"
        orUsage (x:xs)
            | x == CertificateUsageAccept = CertificateUsageAccept
            | otherwise                   = orUsage xs

        toAltName (ExtSubjectAltName l) = l
        matchDomain l
            | length (filter (== "") l) > 0 = rejectMisc "commonname OID got empty subdomain"
            | head l == "*"                 = wildcardMatch (reverse $ drop 1 l)
            | otherwise                     = if l == splitDot fqhn
                then CertificateUsageAccept
                else rejectMisc "FQDN and common name OID do not match"

        -- only 1 wildcard is valid, and if multiples are present
        -- they won't have a wildcard meaning but will be match as normal star
        -- character to the fqhn and inevitably will fail.
        wildcardMatch l
            -- <star>.com or <star> is always invalid
            | length l < 2                         = rejectMisc "commonname OID wildcard match too widely"
            -- <star>.com.<country> is always invalid
            | length (head l) <= 2 && length (head $ drop 1 l) <= 3 && length l < 3 = rejectMisc "commonname OID wildcard match too widely"
            | otherwise                            =
                if l == take (length l) (reverse $ splitDot fqhn)
                    then CertificateUsageAccept
                    else rejectMisc "FQDN and common name OID do not match"

        splitDot :: String -> [String]
        splitDot [] = [""]
        splitDot x  =
            let (y, z) = break (== '.') x in
            y : (if z == "" then [] else splitDot $ drop 1 z)

        rejectMisc s = CertificateUsageReject (CertificateRejectOther s)

-- | Verify certificate validity period that need to between the bounds of the certificate.
-- TODO: maybe should verify whole chain.
certificateVerifyValidity :: Day -> [X509] -> CertificateUsage
certificateVerifyValidity _ []                         = CertificateUsageReject $ CertificateRejectOther "empty list"
certificateVerifyValidity ctime (X509 cert _ _ _ _ :_) =
    let ((beforeDay,_,_) , (afterDay,_,_)) = certValidity cert in
    if beforeDay < ctime && ctime <= afterDay
        then CertificateUsageAccept
        else CertificateUsageReject CertificateRejectExpired

-- | hash the certificate signing data using the supplied hash function.
certificateFingerprint :: (L.ByteString -> B.ByteString) -> X509 -> B.ByteString
certificateFingerprint hash x509 = hash $ getSigningData x509
