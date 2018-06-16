{- IP addresses
 -
 - Copyright 2012 Joey Hess <id@joeyh.name>
 -
 - License: BSD-2-clause
 -}

module Utility.IPAddress where

import Utility.Exception

import Network.Socket
import Data.Word
import Control.Applicative
import Prelude

{- Check if an IP address is a loopback address; connecting to it
 - may connect back to the local host. -}
isLoopbackAddress :: SockAddr -> Bool
isLoopbackAddress (SockAddrInet _ ipv4) = case hostAddressToTuple ipv4 of
	-- localhost
	(127,_,_,_) -> True
	-- current network; functions equivilant to loopback
	(0,_,_, _) -> True
	_ -> False
isLoopbackAddress (SockAddrInet6 _ _ ipv6 _) = case hostAddress6ToTuple ipv6 of
	-- localhost
	(0,0,0,0,0,0,0,1) -> True
	-- unspecified address; functions equivilant to loopback
	(0,0,0,0,0,0,0,0) -> True
	v -> maybe False
		(isLoopbackAddress . SockAddrInet 0)
		(embeddedIpv4 v)
isLoopbackAddress _ = False

{- Check if an IP address is not globally routed, and is used
 - for private communication, eg on a LAN. -}
isPrivateAddress :: SockAddr -> Bool
isPrivateAddress (SockAddrInet _ ipv4) = case hostAddressToTuple ipv4 of
	-- lan
	(10,_,_,_) -> True
	(172,n,_,_) | n >= 16 && n <= 31 -> True -- 172.16.0.0/12
	(192,168,_,_) -> True
	-- carrier-grade NAT
	(100,n,0,0) | n >= 64 && n <= 127 -> True -- 100.64.0.0/10
	-- link-local
	(169,254,_,_) -> True
	_ -> False
isPrivateAddress (SockAddrInet6 _ _ ipv6 _) = case hostAddress6ToTuple ipv6 of
	v@(n,_,_,_,_,_,_,_)
		-- local to lan or private between orgs
		| n >= 0xfc00 && n <= 0xfdff -> True -- fc00::/7
		-- link-local
		| n >= 0xfe80 && n <= 0xfebf -> True --  fe80::/10
		| otherwise -> maybe False
			(isPrivateAddress . SockAddrInet 0)
			(embeddedIpv4 v)
isPrivateAddress _ = False

embeddedIpv4 :: (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16) -> Maybe HostAddress
embeddedIpv4 v = case v of
	-- IPv4 mapped address (::ffff:0:0/96)
	(0,0,0,0,0,0xffff,a,b) -> Just (toipv4 a b)
	-- IPV4 translated address (::ffff:0:ipv4)
	(0,0,0,0,0xffff,0,a,b) -> Just (toipv4 a b)
	-- IPV4/IPV6 translation (64:ff9b::ipv4)
	(0x64,0xff9b,0,0,0,0,a,b) -> Just (toipv4 a b)
	_ -> Nothing
  where
	toipv4 a b = htonl $ fromIntegral a * (2^halfipv4bits) + fromIntegral b
	halfipv4bits = 16 :: Word32
