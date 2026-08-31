#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <winhttp.h>
#include <string>
#include <unordered_map>
#include <memory>
#include <queue>
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include <utility>

#include "curl_bridge.h"

// Translation provider mode
enum class TranslationProvider {
    GOOGLE_FREE = 0,   // translate.googleapis.com gtx endpoint, no key needed (default)
    CUSTOM_HTTP = 1    // user-configured HTTPS JSON endpoint (self-hosted, LibreTranslate, etc.)
};

enum class TranslationResult {
    SUCCESS = 0,
    NETWORK_ERROR = 1,
    API_ERROR = 2,
    ENCODING_ERROR = 3,
    TIMEOUT_ERROR = 4,
    INVALID_PARAMS = 5,
    PENDING = 6,
    RATE_LIMITED = 7
};

struct AsyncRequest {
    std::string requestId;
    std::string text;
    std::string sourceLang;
    std::string targetLang;
    DWORD timestamp;

    AsyncRequest() : sourceLang("zh"), targetLang("en"), timestamp(0) {}
    AsyncRequest(const std::string& id, const std::string& t,
                 const std::string& src = "zh", const std::string& tgt = "en")
        : requestId(id), text(t), sourceLang(src), targetLang(tgt),
          timestamp(GetTickCount()) {}
};

struct AsyncResult {
    std::string requestId;
    std::string translation;
    std::string error;
    bool ready;

    AsyncResult() : ready(false) {}
    AsyncResult(const std::string& id, const std::string& trans,
                const std::string& err)
        : requestId(id), translation(trans), error(err), ready(true) {}
};

struct CacheEntry {
    std::string translation;
    DWORD timestamp;

    CacheEntry() : translation(""), timestamp(0) {}
    CacheEntry(const std::string& trans)
        : translation(trans), timestamp(GetTickCount()) {}
};

class TranslationClient {
private:
    HINTERNET hSession;  // used only by the CUSTOM_HTTP provider (Google Free's fallback chain is curl-backed — see curl_bridge.cpp)
    std::unordered_map<std::string, CacheEntry> cache;
    bool initialized;

    // Provider mode + config (guarded by configMutex; can change while the worker thread runs)
    TranslationProvider provider;
    mutable std::mutex configMutex;

    std::string customEndpoint;
    std::string customApiKey;
    std::string customAuthHeader;
    std::string customAuthScheme;
    std::string customRequestTemplate;
    std::string customResponsePath;

    std::string lastError;
    DWORD lastHttpStatus;

    std::queue<AsyncRequest> requestQueue;
    std::queue<AsyncResult> resultQueue;
    std::mutex requestMutex;
    std::mutex resultMutex;
    std::thread workerThread;
    std::atomic<bool> running;

    static const DWORD CACHE_EXPIRY_MS = 3600000;
    static const size_t MAX_CACHE_SIZE = 500;

    struct ParsedUrl {
        bool valid;
        std::string scheme;
        std::string host;
        int port;
        std::string pathAndQuery;

        ParsedUrl() : valid(false), port(443), pathAndQuery("/") {}
    };

    std::string UrlEncode(const std::string& text);
    std::string HttpsGetGoogleFree(const std::string& path);  // curl-backed GET to translate.googleapis.com (gtx)
    std::string MapLangCode(const std::string& lang);              // Google-style codes (zh -> zh-CN), used by gtx and dict-chrome-ex
    std::string MapLangCodeMicrosoft(const std::string& lang);      // Microsoft-style codes (zh -> zh-Hans), used by Edge Translate
    std::string ParseGoogleFreeResponse(const std::string& json);
    std::string GenerateCacheKey(const std::string& text,
                                 const std::string& sourceLang,
                                 const std::string& targetLang);
    void CleanExpiredCache();
    void WorkerThreadFunc();

    // Custom HTTP provider support
    ParsedUrl ParseUrl(const std::string& url) const;
    std::string HttpsJsonRequest(const ParsedUrl& url,
                                 const std::string& postData,
                                 const std::vector<std::pair<std::string, std::string>>& headers,
                                 DWORD& statusCode,
                                 bool useGet = false);

    // GOOGLE_FREE is actually a fallback CHAIN of unofficial, keyless endpoints
    // reverse-engineered from real Google/Microsoft clients: gtx is tried first
    // (unchanged, original behavior); on failure (429/network/parse error) these
    // are tried in order before giving up. None of these have an SLA either - this
    // only helps when they aren't ALL down/blocked at the same time.
    //   - gtx:            translate.googleapis.com/translate_a/single (Google Translate website)
    //   - tw-ob:          translate.googleapis.com/translate_a/single, same endpoint/response
    //                      shape as gtx, just a different client id (Google's "Translate Web"
    //                      mobile client) - a distinct rate-limit bucket from gtx for free
    //   - dict-chrome-ex: clients5.google.com/translate_a/t (Google Dictionary Chrome extension)
    //   - edge-translate: api.cognitive.microsofttranslator.com via edge.microsoft.com's
    //                      anonymous auth token (Microsoft Edge's built-in translate feature)
    TranslationResult TranslateWithGoogleFree(const std::string& text, std::string& result,
                                              const std::string& sourceLang, const std::string& targetLang);
    TranslationResult TranslateWithGtx(const std::string& text, std::string& result,
                                       const std::string& sourceLang, const std::string& targetLang);
    TranslationResult TranslateWithTwOb(const std::string& text, std::string& result,
                                        const std::string& sourceLang, const std::string& targetLang);
    // Shared by TranslateWithGtx and TranslateWithTwOb: both hit
    // translate.googleapis.com/translate_a/single with the same params, differing
    // only in the "client" query value, and parse the same [[[...]]] response shape.
    TranslationResult TranslateWithGoogleSingleClient(const std::string& clientId,
                                                       const std::string& text, std::string& result,
                                                       const std::string& sourceLang, const std::string& targetLang);
    TranslationResult TranslateWithDictChromeEx(const std::string& text, std::string& result,
                                                const std::string& sourceLang, const std::string& targetLang);
    TranslationResult TranslateWithEdgeTranslate(const std::string& text, std::string& result,
                                                 const std::string& sourceLang, const std::string& targetLang);
    bool GetEdgeAuthToken(std::string& outToken, std::string& outError);

    std::mutex edgeTokenMutex;
    std::string cachedEdgeToken;
    DWORD edgeTokenExpiresTick;  // GetTickCount() value after which the cached token is treated as stale

    TranslationResult TranslateWithCustom(const std::string& text, std::string& result,
                                          const std::string& sourceLang, const std::string& targetLang);
    void SetLastError(const std::string& error);
    void SetLastHttpStatus(DWORD status);

public:
    TranslationClient();
    ~TranslationClient();

    // Back-compat: connects the GOOGLE_FREE provider (what earlier versions did unconditionally).
    bool Initialize();

    bool ConfigureGoogleFree();
    bool ConfigureCustomHttp(const std::string& endpoint,
                             const std::string& apiKey,
                             const std::string& authHeader,
                             const std::string& authScheme,
                             const std::string& requestTemplate,
                             const std::string& responsePath);
    // Reads WoWTranslate.ini next to the DLL, if present. Returns false (and leaves
    // the client unconfigured) if the file is missing or its provider type is unknown.
    bool LoadConfigFromIni();

    void Cleanup();
    bool IsInitialized() const { return initialized; }

    TranslationProvider GetProvider() const { return provider; }
    std::string GetProviderName() const;
    std::string GetProviderEndpoint() const;
    std::string GetProviderStatusJson() const;
    std::string GetLastError() const;
    DWORD GetLastHttpStatus() const { return lastHttpStatus; }

    TranslationResult TranslateText(const std::string& text, std::string& result,
                                    const std::string& sourceLang = "zh",
                                    const std::string& targetLang = "en");

    bool TranslateAsync(const std::string& requestId, const std::string& text,
                        const std::string& sourceLang = "zh",
                        const std::string& targetLang = "en");
    bool PollResult(std::string& requestId, std::string& translation,
                    std::string& error);
    size_t GetPendingCount();
};

extern std::unique_ptr<TranslationClient> g_translator;
extern char g_translation_buffer[4096];
extern char g_error_buffer[256];
