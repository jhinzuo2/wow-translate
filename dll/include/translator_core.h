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
    HINTERNET hSession;  // used only by the CUSTOM_HTTP provider (Google Free is WinINet-backed — see wininet_bridge.cpp)
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
    std::string HttpsGetGoogleFree(const std::string& path);  // WinINet-backed GET to translate.googleapis.com
    std::string MapLangCode(const std::string& lang);
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
    TranslationResult TranslateWithGoogleFree(const std::string& text, std::string& result,
                                              const std::string& sourceLang, const std::string& targetLang);
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
