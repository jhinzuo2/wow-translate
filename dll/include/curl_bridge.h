#pragma once

// A single HTTPS GET issued through libcurl (statically linked against OpenSSL),
// used in place of wininet_bridge's WinInetHttpsGet for the Google Free provider.
//
// WHY THIS EXISTS: both WinHTTP and WinINet hand TLS off to the OS's Schannel.
// This 32-bit DLL runs under WOW64, and WOW64's Schannel (syswow64\schannel.dll,
// configured via the HKLM\...\WOW6432Node\...\SCHANNEL registry path) produces a
// different ClientHello fingerprint than native 64-bit Schannel — different cipher
// suite list/order and extension set. Google's abuse detection appears to key off
// that TLS fingerprint independent of headers/User-Agent, which is why WinHTTP and
// WinINet both got 429'd from this process despite matching request headers.
//
// Statically linking libcurl against OpenSSL removes Schannel from the picture
// entirely: curl does its own TLS handshake with its own cipher list/extension
// order, so the fingerprint no longer depends on OS bitness or WOW64 registry
// config at all. If Google's block is genuinely fingerprint-based, this fixes it
// for both x86 and x64 builds; if it's something else, this at least removes
// bitness as a variable so it's not fought at every layer separately.
//
// curl_global_init/cleanup are NOT thread-safe and must not race other curl use.

#include <string>
#include <vector>
#include <utility>
#include <cstdint>

// Idempotent, thread-safe (std::call_once-guarded) lazy init. CurlHttpsGet calls
// this itself, so callers don't need to - exposed mainly so a caller can surface
// an init failure explicitly if desired. Deliberately NOT meant to be called from
// DllMain: curl_global_init() can call LoadLibrary internally, which risks a
// loader-lock deadlock if called during DLL_PROCESS_ATTACH. The worker thread's
// first request (well after attach) is the right place - see curl_bridge.cpp.
bool CurlBridgeGlobalInit(std::string& outError);

// Call once from DllMain (DLL_PROCESS_DETACH), after the worker thread that makes
// CurlHttpsGet calls has been joined (curl_global_cleanup does not itself risk a
// loader-lock deadlock the way init does, so DLL_PROCESS_DETACH is fine for this).
void CurlBridgeGlobalCleanup();

// Same contract as WinInetHttpsGet: returns the response body (may be non-empty
// even on a non-2xx status — callers should check statusCode). Returns an empty
// string with a non-empty outError only when the request could not be sent/
// received at all (network failure, TLS failure, timeout).
std::string CurlHttpsGet(const std::string& host,
                          int port,
                          const std::string& pathAndQuery,
                          const std::vector<std::pair<std::string, std::string>>& headers,
                          long& statusCode,
                          std::string& outError);

// Same contract as CurlHttpsGet, but issues a POST with the given body (e.g. a
// JSON payload). Content-Type is NOT set automatically — include it in headers
// if the target expects one (most JSON APIs do).
std::string CurlHttpsPost(const std::string& host,
                           int port,
                           const std::string& pathAndQuery,
                           const std::string& body,
                           const std::vector<std::pair<std::string, std::string>>& headers,
                           long& statusCode,
                           std::string& outError);
