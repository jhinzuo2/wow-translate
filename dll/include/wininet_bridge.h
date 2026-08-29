#pragma once

// Deliberately does NOT include wininet.h here. translator_core.h/.cpp already
// includes winhttp.h (used by the custom-HTTP provider), and wininet.h/winhttp.h
// both declare an HINTERNET typedef plus a family of similarly-prefixed constants —
// keeping them out of the same translation unit avoids any risk of collision.
// windows.h alone (for DWORD) is enough for this signature.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <string>
#include <vector>
#include <utility>

// A single HTTPS GET issued through WinINet (wininet.dll) rather than WinHTTP.
// Used only by the Google Free provider: WinHTTP's traffic was getting blocked by
// Google's gtx abuse detection even after matching headers and default TLS/HTTP
// negotiation, while a WinINet-backed client (PowerShell's Invoke-WebRequest, which
// goes through System.Net.HttpWebRequest -> WinINet) was not. This isolates that
// same stack for the DLL's own requests.
//
// Opens and tears down its own InternetOpen/Connect/Request handles per call rather
// than keeping a persistent session — the worker thread already serializes requests,
// so there's no concurrency to share a session across, and this keeps the WinINet
// state fully self-contained in one call with no cross-call handle lifetime to manage.
//
// Returns the response body (may be non-empty even on a non-2xx status — callers
// should check statusCode). Returns an empty string with a non-empty outError only
// when the request could not be sent/received at all (network failure).
std::string WinInetHttpsGet(const std::string& host,
                            int port,
                            const std::string& pathAndQuery,
                            const std::vector<std::pair<std::string, std::string>>& headers,
                            DWORD& statusCode,
                            std::string& outError);
