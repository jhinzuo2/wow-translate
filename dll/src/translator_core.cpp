// translator_core.cpp - Translation functionality for WoWTranslate
// Providers:
//   GOOGLE_FREE - GET requests to translate.googleapis.com (client=gtx), no key needed (default)
//   CUSTOM_HTTP - user-configured HTTPS JSON endpoint (self-hosted proxy, LibreTranslate, etc.)

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <winhttp.h>
#include <string>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <codecvt>
#include <locale>
#include <map>
#include <vector>
#include <cstdio>
#include <stdexcept>

#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include "json.hpp"
#ifdef _MSC_VER
#pragma warning(pop)
#endif

#include "../include/translator_core.h"
#include "../include/logging.h"
#include "../include/utils.h"

using namespace std;
using json = nlohmann::json;

namespace {

string ToLowerCopy(string value) {
    transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(tolower(c));
    });
    return value;
}

wstring ToWide(const string& value) {
    return wstring(value.begin(), value.end());
}

void ReplaceAll(string& value, const string& from, const string& to) {
    if (from.empty()) {
        return;
    }

    size_t pos = 0;
    while ((pos = value.find(from, pos)) != string::npos) {
        value.replace(pos, from.length(), to);
        pos += to.length();
    }
}

// Escapes a value for embedding inside a JSON string literal in a request template
// (i.e. what you'd put between the quotes). error_handler_t::replace: chat text can
// contain invalid UTF-8 (server truncates at 255 bytes mid-character); a bare dump()
// would throw on that, and this can run on the worker thread.
string JsonTemplateEscape(const string& value) {
    string dumped = json(value).dump(-1, ' ', false, json::error_handler_t::replace);
    if (dumped.length() >= 2 && dumped.front() == '"' && dumped.back() == '"') {
        return dumped.substr(1, dumped.length() - 2);
    }
    return dumped;
}

string MaskSecret(const string& value) {
    if (value.empty()) {
        return "";
    }
    if (value.length() <= 6) {
        return "******";
    }
    return value.substr(0, 3) + "..." + value.substr(value.length() - 3);
}

bool IsSensitiveQueryName(const string& name) {
    string lower = ToLowerCopy(name);
    return lower == "key" || lower == "api_key" || lower == "apikey" ||
           lower == "token" || lower == "access_token";
}

string MaskUrl(const string& url) {
    size_t queryPos = url.find('?');
    if (queryPos == string::npos) {
        return url;
    }

    string result = url.substr(0, queryPos + 1);
    string query = url.substr(queryPos + 1);
    size_t pos = 0;
    bool first = true;

    while (pos <= query.length()) {
        size_t amp = query.find('&', pos);
        string part = (amp == string::npos) ? query.substr(pos) : query.substr(pos, amp - pos);
        size_t eq = part.find('=');

        if (!first) {
            result += "&";
        }
        first = false;

        if (eq != string::npos && IsSensitiveQueryName(part.substr(0, eq))) {
            result += part.substr(0, eq + 1) + "***";
        } else {
            result += part;
        }

        if (amp == string::npos) {
            break;
        }
        pos = amp + 1;
    }

    return result;
}

string ProviderName(TranslationProvider provider) {
    switch (provider) {
        case TranslationProvider::GOOGLE_FREE: return "google_free";
        case TranslationProvider::CUSTOM_HTTP: return "custom";
        default: return "unknown";
    }
}

string TrimCopy(const string& value) {
    return TrimString(value);
}

string JsonErrorMessage(const json& parsed, DWORD httpStatus) {
    try {
        if (parsed.contains("error")) {
            const json& err = parsed["error"];
            if (err.is_string()) {
                return err.get<string>();
            }
            if (err.is_object() && err.contains("message") && err["message"].is_string()) {
                return err["message"].get<string>();
            }
        }
        if (parsed.contains("message") && parsed["message"].is_string()) {
            return parsed["message"].get<string>();
        }
    } catch (...) {
        // Fall through to the HTTP status fallback.
    }

    if (httpStatus > 0) {
        return "HTTP " + to_string(httpStatus);
    }
    return "provider error";
}

// Resolves a dotted / bracketed path like "data.translations[0].translatedText"
// against a parsed JSON response.
bool ExtractJsonPath(const json& root, const string& path, string& outValue) {
    if (path.empty()) {
        return false;
    }

    const json* current = &root;
    size_t pos = 0;

    while (pos < path.length()) {
        size_t dot = path.find('.', pos);
        string segment = (dot == string::npos) ? path.substr(pos) : path.substr(pos, dot - pos);
        pos = (dot == string::npos) ? path.length() : dot + 1;

        if (segment.empty()) {
            return false;
        }

        size_t bracket = segment.find('[');
        string objectKey = bracket == string::npos ? segment : segment.substr(0, bracket);

        if (!objectKey.empty()) {
            if (!current->is_object() || !current->contains(objectKey)) {
                return false;
            }
            current = &(*current)[objectKey];
        }

        while (bracket != string::npos) {
            size_t close = segment.find(']', bracket + 1);
            if (close == string::npos) {
                return false;
            }

            string indexText = segment.substr(bracket + 1, close - bracket - 1);
            if (indexText.empty()) {
                return false;
            }

            int index = atoi(indexText.c_str());
            if (!current->is_array() || index < 0 || static_cast<size_t>(index) >= current->size()) {
                return false;
            }
            current = &(*current)[static_cast<size_t>(index)];
            bracket = segment.find('[', close + 1);
        }
    }

    if (current->is_string()) {
        outValue = current->get<string>();
    } else if (current->is_number() || current->is_boolean()) {
        outValue = current->dump();
    } else {
        return false;
    }

    return !outValue.empty();
}

string IniValue(const map<string, map<string, string>>& ini,
                const string& section,
                const string& key,
                const string& defaultValue = "") {
    auto secIt = ini.find(ToLowerCopy(section));
    if (secIt == ini.end()) {
        return defaultValue;
    }

    auto keyIt = secIt->second.find(ToLowerCopy(key));
    if (keyIt == secIt->second.end()) {
        return defaultValue;
    }

    return keyIt->second;
}

// UTF-8 codepoint encoder (file-scope for use in multiple places)
string ConvertCodepointToUTF8(unsigned int codepoint) {
    string result;
    if (codepoint <= 0x7F) {
        result += static_cast<char>(codepoint);
    } else if (codepoint <= 0x7FF) {
        result += static_cast<char>(0xC0 | (codepoint >> 6));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0xFFFF) {
        result += static_cast<char>(0xE0 | (codepoint >> 12));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0x10FFFF) {
        result += static_cast<char>(0xF0 | (codepoint >> 18));
        result += static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    }
    return result;
}

// HTTP/2 opt-in and TLS-1.2 pinning were both tried here and removed after a live
// A/B test: a bare PowerShell Invoke-WebRequest (default TLS negotiation, HTTP/1.1
// only) succeeded against the exact same endpoint at the exact same time our
// TLS-1.2-pinned, HTTP/2-enabled WinHTTP session was blocked. Forcing either of
// those away from the OS/API default made this session's traffic *less* like a
// normal client, not more — so neither is set here; WinHTTP is left to negotiate
// its own defaults.

// Fetches the full raw response header block ("Name: value\r\n..." pairs, CRLF-terminated)
// for diagnostic logging. Uses the growable-buffer WinHTTP pattern since the header
// block size isn't known up front.
string QueryRawResponseHeaders(HINTERNET hRequest) {
    DWORD size = 0;
    WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                        WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER,
                        &size, WINHTTP_NO_HEADER_INDEX);
    if (size == 0) {
        return "";
    }

    vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
    if (!WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                             WINHTTP_HEADER_NAME_BY_INDEX, buffer.data(),
                             &size, WINHTTP_NO_HEADER_INDEX)) {
        return "";
    }

    wstring wide(buffer.data());
    return string(wide.begin(), wide.end());
}

// Truncates and makes a response body single-line-safe for a log entry.
string PreviewBody(const string& body, size_t maxLen = 400) {
    string preview = body.substr(0, min(body.length(), maxLen));
    ReplaceAll(preview, "\r\n", " | ");
    ReplaceAll(preview, "\n", " | ");
    if (body.length() > maxLen) {
        preview += "... (" + to_string(body.length()) + " bytes total)";
    }
    return preview;
}

} // namespace

// Global variables
unique_ptr<TranslationClient> g_translator = nullptr;
char g_translation_buffer[4096] = {0};
char g_error_buffer[256] = {0};

TranslationClient::TranslationClient()
    : hSession(nullptr),
      initialized(false),
      provider(TranslationProvider::GOOGLE_FREE),
      customAuthHeader("Authorization"),
      customAuthScheme("Bearer"),
      customResponsePath("translation"),
      lastHttpStatus(0),
      running(false),
      edgeTokenExpiresTick(0) {
}

TranslationClient::~TranslationClient() {
    Cleanup();
}

bool TranslationClient::Initialize() {
    return ConfigureGoogleFree();
}

bool TranslationClient::ConfigureGoogleFree() {
    Cleanup();

    {
        lock_guard<mutex> lock(configMutex);
        provider = TranslationProvider::GOOGLE_FREE;
        lastHttpStatus = 0;
    }

    // Google Free is backed by WinINet (see wininet_bridge.cpp), not WinHTTP — a
    // live A/B test showed WinHTTP's traffic getting blocked by Google's gtx abuse
    // detection (even after matching headers and default TLS/HTTP negotiation)
    // while WinINet-backed traffic (what PowerShell's Invoke-WebRequest actually
    // uses) was not. WinInetHttpsGet opens its own handles per request, so there's
    // no persistent session/connection to set up here.
    LOG_INFO("Initializing Google Free translation client (WinINet)");

    running = true;
    workerThread = thread(&TranslationClient::WorkerThreadFunc, this);
    initialized = true;
    SetLastError("");
    LOG_INFO("Google Free translation client initialized");
    return true;
}

bool TranslationClient::ConfigureCustomHttp(const string& endpoint,
                                            const string& apiKey,
                                            const string& authHeader,
                                            const string& authScheme,
                                            const string& requestTemplate,
                                            const string& responsePath) {
    ParsedUrl parsed = ParseUrl(endpoint);
    if (!parsed.valid) {
        SetLastError("Custom endpoint must be a valid HTTPS URL");
        return false;
    }

    Cleanup();

    {
        lock_guard<mutex> lock(configMutex);
        provider = TranslationProvider::CUSTOM_HTTP;
        customEndpoint = endpoint;
        customApiKey = apiKey;
        customAuthHeader = authHeader.empty() ? "Authorization" : authHeader;
        customAuthScheme = authScheme;
        customRequestTemplate = requestTemplate.empty()
            ? "{\"text\":\"{text}\",\"source\":\"{source}\",\"target\":\"{target}\"}"
            : requestTemplate;
        customResponsePath = responsePath.empty() ? "translation" : responsePath;
        lastHttpStatus = 0;
    }

    // The custom provider opens a fresh WinHttpConnect per request scoped to whatever
    // host the endpoint points at, so all it needs up front is a plain WinHTTP session.
    LOG_INFO("Initializing custom HTTP translation client: " + MaskUrl(endpoint));

    hSession = WinHttpOpen(L"WoWTranslate/1.0",
                           WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                           WINHTTP_NO_PROXY_NAME,
                           WINHTTP_NO_PROXY_BYPASS,
                           0);
    if (!hSession) {
        SetLastError("failed to initialize WinHTTP");
        LOG_ERROR("Failed to initialize WinHTTP session");
        return false;
    }

    WinHttpSetTimeouts(hSession, 5000, 5000, 15000, 30000);
    // Deliberately NOT pinning TLS version or opting into HTTP/2 here: a live A/B
    // test showed a bare PowerShell Invoke-WebRequest (default TLS negotiation --
    // TLS 1.3 on modern Windows -- and HTTP/1.1 only, since HttpWebRequest never
    // speaks HTTP/2) succeeds where our TLS-1.2-pinned, HTTP/2-enabled WinHTTP
    // session gets blocked. Matching PowerShell means doing LESS here, not more --
    // let WinHTTP negotiate its own OS default instead of forcing anything.

    running = true;
    workerThread = thread(&TranslationClient::WorkerThreadFunc, this);
    initialized = true;
    SetLastError("");
    LOG_INFO("Custom HTTP translation client initialized");
    return true;
}

bool TranslationClient::LoadConfigFromIni() {
    string dllPath = GetDllPath();
    if (dllPath.empty()) {
        return false;
    }

    size_t slash = dllPath.find_last_of("\\/");
    string dllDir = slash == string::npos ? "." : dllPath.substr(0, slash);
    string iniPath = dllDir + "\\WoWTranslate.ini";

    ifstream iniFile(iniPath);
    if (!iniFile.is_open()) {
        LOG_INFO("No WoWTranslate.ini found next to DLL");
        return false;
    }

    map<string, map<string, string>> ini;
    string section;
    string line;

    while (getline(iniFile, line)) {
        line = TrimCopy(line);
        if (line.empty() || line[0] == ';' || line[0] == '#') {
            continue;
        }

        if (line.front() == '[' && line.back() == ']') {
            section = ToLowerCopy(TrimCopy(line.substr(1, line.length() - 2)));
            continue;
        }

        size_t eq = line.find('=');
        if (eq == string::npos || section.empty()) {
            continue;
        }

        string key = ToLowerCopy(TrimCopy(line.substr(0, eq)));
        string value = TrimCopy(line.substr(eq + 1));
        ini[section][key] = value;
    }

    string type = ToLowerCopy(IniValue(ini, "provider", "type", "google_free"));
    LOG_INFO("Loading provider configuration from WoWTranslate.ini: " + type);

    if (type == "google_free" || type == "googlefree" || type == "free") {
        return ConfigureGoogleFree();
    }

    if (type == "custom") {
        return ConfigureCustomHttp(
            IniValue(ini, "custom", "endpoint"),
            IniValue(ini, "custom", "api_key"),
            IniValue(ini, "custom", "auth_header", "Authorization"),
            IniValue(ini, "custom", "auth_scheme", "Bearer"),
            IniValue(ini, "custom", "request_template"),
            IniValue(ini, "custom", "response_path", "translation"));
    }

    SetLastError("unknown provider in WoWTranslate.ini: " + type);
    return false;
}

void TranslationClient::Cleanup() {
    // Stop worker thread
    if (running) {
        running = false;
        if (workerThread.joinable()) {
            workerThread.join();
        }
    }

    if (hSession) {
        WinHttpCloseHandle(hSession);
        hSession = nullptr;
    }

    {
        lock_guard<mutex> lock(requestMutex);
        queue<AsyncRequest> empty;
        swap(requestQueue, empty);
    }

    {
        lock_guard<mutex> lock(resultMutex);
        queue<AsyncResult> empty;
        swap(resultQueue, empty);
    }

    cache.clear();
    initialized = false;
    LOG_INFO("Translation client cleanup complete");
}

string TranslationClient::GetProviderName() const {
    lock_guard<mutex> lock(configMutex);
    return ProviderName(provider);
}

string TranslationClient::GetProviderEndpoint() const {
    lock_guard<mutex> lock(configMutex);
    if (provider == TranslationProvider::GOOGLE_FREE) {
        return "https://translate.googleapis.com/translate_a/single (free, no key)";
    }
    return MaskUrl(customEndpoint);
}

string TranslationClient::GetProviderStatusJson() const {
    lock_guard<mutex> lock(configMutex);

    string endpoint = (provider == TranslationProvider::GOOGLE_FREE)
        ? "https://translate.googleapis.com/translate_a/single (free, no key)"
        : MaskUrl(customEndpoint);

    bool configured = (provider == TranslationProvider::GOOGLE_FREE)
        ? true
        : (!customEndpoint.empty() && !customRequestTemplate.empty() && !customResponsePath.empty());

    json status;
    status["provider"] = ProviderName(provider);
    status["configured"] = configured;
    status["ready"] = initialized;
    status["endpoint"] = endpoint;
    status["lastHttpStatus"] = lastHttpStatus;
    return status.dump(-1, ' ', false, json::error_handler_t::replace);
}

string TranslationClient::GetLastError() const {
    lock_guard<mutex> lock(configMutex);
    return lastError;
}

void TranslationClient::SetLastError(const string& error) {
    lock_guard<mutex> lock(configMutex);
    lastError = error;
}

void TranslationClient::SetLastHttpStatus(DWORD status) {
    lock_guard<mutex> lock(configMutex);
    lastHttpStatus = status;
}

string TranslationClient::UrlEncode(const string& text) {
    ostringstream encoded;
    encoded.fill('0');
    encoded << hex;

    for (unsigned char c : text) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            encoded << c;
        } else {
            encoded << uppercase;
            encoded << '%' << setw(2) << static_cast<int>(c);
            encoded << nouppercase;
        }
    }

    return encoded.str();
}

string TranslationClient::GenerateCacheKey(const string& text, const string& sourceLang, const string& targetLang) {
    return ProviderName(provider) + ":" + sourceLang + "->" + targetLang + ":" + text;
}

void TranslationClient::CleanExpiredCache() {
    DWORD currentTime = GetTickCount();
    auto it = cache.begin();

    while (it != cache.end()) {
        if (currentTime - it->second.timestamp > CACHE_EXPIRY_MS) {
            it = cache.erase(it);
        } else {
            ++it;
        }
    }

    if (cache.size() > MAX_CACHE_SIZE) {
        size_t removeCount = cache.size() - MAX_CACHE_SIZE / 2;
        for (size_t i = 0; i < removeCount && !cache.empty(); ++i) {
            cache.erase(cache.begin());
        }
    }
}

string TranslationClient::MapLangCode(const string& lang) {
    if (lang == "zh") return "zh-CN";
    // ja, ko, ru, en are already valid Google lang codes
    return lang;
}

string TranslationClient::HttpsGetGoogleFree(const string& path) {
    vector<pair<string, string>> headers = {
        {"Accept", "*/*"},
        {"Accept-Language", "en-US,en;q=0.9"}
    };
    // Note: User-Agent is set inside CurlHttpsGet itself (via CURLOPT_USERAGENT)
    // rather than passed here.
    //
    // Google Free now goes through curl_bridge (libcurl + OpenSSL) instead of
    // WinINet. Both WinHTTP and WinINet hand TLS to the OS's Schannel, and this
    // DLL runs 32-bit under WOW64, whose Schannel produces a different TLS
    // fingerprint than native 64-bit Schannel — that's the likely reason Google's
    // abuse detection was 429'ing WinINet requests too, despite matching headers.
    // Statically linking curl against OpenSSL removes Schannel/WOW64 from the
    // picture entirely. See curl_bridge.h for the full writeup.

    long statusCodeLong = 0;
    string error;
    string response = CurlHttpsGet("translate.googleapis.com", 443, path, headers, statusCodeLong, error);
    DWORD statusCode = static_cast<DWORD>(statusCodeLong);
    SetLastHttpStatus(statusCode);

    if (statusCode == 0) {
        // Request never got a response at all (DNS/connect/send failure).
        SetLastError(error.empty() ? "network error" : error);
        return "";
    }

    if (statusCode == 429) {
        LOG_WARNING("Rate limited by Google (HTTP 429)");
        return "HTTP_429";
    }

    return response;
}

// Generic HTTPS JSON request used by the custom provider: opens its own connection
// scoped to whatever host the configured endpoint points at (unlike the Google Free
// path, which goes through WinINet instead — see wininet_bridge.cpp).
string TranslationClient::HttpsJsonRequest(const ParsedUrl& url,
                                           const string& postData,
                                           const vector<pair<string, string>>& headers,
                                           DWORD& statusCode,
                                           bool useGet) {
    statusCode = 0;

    if (!hSession || !url.valid) {
        SetLastError("HTTP runtime is not ready");
        return "";
    }

    wstring wHost = ToWide(url.host);
    HINTERNET hReqConnect = WinHttpConnect(hSession,
                                           wHost.c_str(),
                                           static_cast<INTERNET_PORT>(url.port),
                                           0);
    if (!hReqConnect) {
        DWORD err = ::GetLastError();
        SetLastError("failed to connect to " + url.host + " (" + to_string(err) + ")");
        LOG_ERROR("WinHttpConnect failed for " + url.host + ": " + to_string(err));
        return "";
    }

    wstring wPath = ToWide(url.pathAndQuery);
    HINTERNET hRequest = WinHttpOpenRequest(hReqConnect,
                                            useGet ? L"GET" : L"POST",
                                            wPath.c_str(),
                                            nullptr,
                                            WINHTTP_NO_REFERER,
                                            WINHTTP_DEFAULT_ACCEPT_TYPES,
                                            WINHTTP_FLAG_SECURE);

    if (!hRequest) {
        DWORD err = ::GetLastError();
        WinHttpCloseHandle(hReqConnect);
        SetLastError("failed to open HTTP request (" + to_string(err) + ")");
        LOG_ERROR("WinHttpOpenRequest failed: " + to_string(err));
        return "";
    }

    string headerText = useGet ? "" : "Content-Type: application/json\r\n";
    headerText += "Accept: application/json\r\n";
    for (const auto& header : headers) {
        if (!header.first.empty() && !header.second.empty()) {
            headerText += header.first + ": " + header.second + "\r\n";
        }
    }

    wstring wHeaders = ToWide(headerText);
    if (!WinHttpAddRequestHeaders(hRequest, wHeaders.c_str(), (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD)) {
        LOG_WARNING("WinHttpAddRequestHeaders failed");
    }

    LOG_DEBUG(string(useGet ? "GET" : "POST") + " https://" + url.host + ":" + to_string(url.port) + MaskUrl(url.pathAndQuery));

    BOOL sent = WinHttpSendRequest(hRequest,
                                   WINHTTP_NO_ADDITIONAL_HEADERS,
                                   0,
                                   (useGet || postData.empty()) ? WINHTTP_NO_REQUEST_DATA : (LPVOID)postData.c_str(),
                                   useGet ? 0 : static_cast<DWORD>(postData.length()),
                                   useGet ? 0 : static_cast<DWORD>(postData.length()),
                                   0);

    string response;
    if (sent && WinHttpReceiveResponse(hRequest, nullptr)) {
        DWORD statusSize = sizeof(statusCode);
        WinHttpQueryHeaders(hRequest,
                            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX,
                            &statusCode,
                            &statusSize,
                            WINHTTP_NO_HEADER_INDEX);
        SetLastHttpStatus(statusCode);

        DWORD bytesAvailable = 0;
        char buffer[8192];

        while (WinHttpQueryDataAvailable(hRequest, &bytesAvailable) && bytesAvailable > 0) {
            DWORD bytesRead = 0;
            DWORD bytesToRead = std::min(bytesAvailable, static_cast<DWORD>(sizeof(buffer)));

            if (!WinHttpReadData(hRequest, buffer, bytesToRead, &bytesRead) || bytesRead == 0) {
                break;
            }

            response.append(buffer, bytesRead);
        }

        if (statusCode >= 400) {
            LOG_WARNING("Custom provider response status: " + to_string(statusCode));
            LOG_WARNING("Custom provider response headers: " + QueryRawResponseHeaders(hRequest));
            LOG_WARNING("Custom provider response body: " + PreviewBody(response));
        } else {
            LOG_DEBUG("Custom provider response status: " + to_string(statusCode) +
                     ", " + to_string(response.length()) + " bytes");
        }
    } else {
        DWORD err = ::GetLastError();
        SetLastError("HTTP request failed (" + to_string(err) + ")");
        LOG_ERROR("HTTP request failed with WinHTTP error: " + to_string(err));
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hReqConnect);
    return response;
}

TranslationClient::ParsedUrl TranslationClient::ParseUrl(const string& url) const {
    ParsedUrl parsed;
    size_t schemeEnd = url.find("://");
    if (schemeEnd == string::npos) {
        return parsed;
    }

    parsed.scheme = ToLowerCopy(url.substr(0, schemeEnd));
    if (parsed.scheme != "https") {
        return parsed;
    }

    string remainder = url.substr(schemeEnd + 3);
    size_t pathStart = remainder.find_first_of("/?");
    string hostPort = pathStart == string::npos ? remainder : remainder.substr(0, pathStart);
    if (pathStart == string::npos) {
        parsed.pathAndQuery = "/";
    } else if (remainder[pathStart] == '?') {
        parsed.pathAndQuery = "/" + remainder.substr(pathStart);
    } else {
        parsed.pathAndQuery = remainder.substr(pathStart);
    }

    if (hostPort.empty()) {
        return parsed;
    }

    size_t colon = hostPort.rfind(':');
    if (colon != string::npos && colon + 1 < hostPort.length()) {
        string portText = hostPort.substr(colon + 1);
        bool allDigits = true;
        for (char ch : portText) {
            if (!isdigit(static_cast<unsigned char>(ch))) {
                allDigits = false;
                break;
            }
        }

        if (allDigits) {
            parsed.host = hostPort.substr(0, colon);
            parsed.port = atoi(portText.c_str());
        } else {
            parsed.host = hostPort;
            parsed.port = 443;
        }
    } else {
        parsed.host = hostPort;
        parsed.port = 443;
    }

    parsed.valid = !parsed.host.empty() && parsed.port > 0;
    return parsed;
}

string TranslationClient::ParseGoogleFreeResponse(const string& json) {
    string result;

    // Find the start of the sentence array: [[[
    size_t pos = json.find("[[[");
    if (pos == string::npos) return "";
    pos += 3; // now at opening " of first translated segment

    // Upper bound: the ]] that closes the outer sentence array
    size_t sentencesEnd = json.find("]]", pos);

    while (pos < json.size()) {
        if (json[pos] != '"') break;
        pos++; // skip opening "

        string segment;
        while (pos < json.size() && json[pos] != '"') {
            if (json[pos] == '\\' && pos + 1 < json.size()) {
                pos++;
                switch (json[pos]) {
                    case '"':  segment += '"';  break;
                    case '\\': segment += '\\'; break;
                    case 'n':  segment += '\n'; break;
                    case 'r':  segment += '\r'; break;
                    case 't':  segment += '\t'; break;
                    case 'u': {
                        if (pos + 4 < json.size()) {
                            string hex = json.substr(pos + 1, 4);
                            try {
                                unsigned int cp = stoul(hex, nullptr, 16);
                                segment += ConvertCodepointToUTF8(cp);
                                pos += 4;
                            } catch (...) {}
                        }
                        break;
                    }
                    default: segment += json[pos]; break;
                }
            } else {
                segment += json[pos];
            }
            pos++;
        }
        result += segment;
        if (pos < json.size()) pos++; // skip closing "

        // Find next inner array: ,["  within the sentence array bounds
        size_t nextInner = json.find(",[\"", pos);
        if (nextInner == string::npos ||
            (sentencesEnd != string::npos && nextInner > sentencesEnd)) break;
        pos = nextInner + 2; // point at the opening " of next segment
    }

    return result;
}

// The GOOGLE_FREE provider is a fallback chain: gtx is tried first (this is the
// original, unchanged behavior), then dict-chrome-ex, then edge-translate, in
// that order. All three are free/keyless — see translator_core.h for what each
// one actually is.
TranslationResult TranslationClient::TranslateWithGoogleFree(const string& text, string& result,
                                                              const string& sourceLang, const string& targetLang) {
    struct FreeBackend {
        const char* name;
        TranslationResult (TranslationClient::*fn)(const string&, string&, const string&, const string&);
    };
    static const FreeBackend backends[] = {
        {"gtx",            &TranslationClient::TranslateWithGtx},
        {"dict-chrome-ex", &TranslationClient::TranslateWithDictChromeEx},
        {"edge-translate", &TranslationClient::TranslateWithEdgeTranslate},
    };
    static const size_t backendCount = sizeof(backends) / sizeof(backends[0]);

    TranslationResult lastResult = TranslationResult::NETWORK_ERROR;

    for (size_t i = 0; i < backendCount; ++i) {
        result.clear();
        lastResult = (this->*backends[i].fn)(text, result, sourceLang, targetLang);

        if (lastResult == TranslationResult::SUCCESS) {
            if (i > 0) {
                LOG_INFO(string("Free-tier fallback: ") + backends[i].name +
                         " succeeded after " + to_string(i) + " earlier backend(s) failed");
            }
            return TranslationResult::SUCCESS;
        }

        bool haveMoreBackends = (i + 1 < backendCount);
        LOG_WARNING(string(backends[i].name) + " failed (" +
                    (lastResult == TranslationResult::RATE_LIMITED ? "rate limited" : "error") +
                    (result.empty() ? "" : ": " + result) + ")" +
                    (haveMoreBackends ? " - trying next free backend" : " - all free backends exhausted"));
    }

    return lastResult;
}

TranslationResult TranslationClient::TranslateWithGtx(const string& text, string& result,
                                                       const string& sourceLang, const string& targetLang) {
    // Build Google Free GET path
    string sl = MapLangCode(sourceLang);
    string tl = MapLangCode(targetLang);
    string path = "/translate_a/single?client=gtx&sl=" + sl +
                  "&tl=" + tl + "&dt=t&q=" + UrlEncode(text);

    LOG_DEBUG("GET " + path.substr(0, 120));

    string response = HttpsGetGoogleFree(path);

    if (response == "HTTP_429") {
        return TranslationResult::RATE_LIMITED;
    }

    if (response.empty()) {
        LOG_ERROR("Empty response from Google Free");
        result = "network error";
        SetLastError(result);
        return TranslationResult::NETWORK_ERROR;
    }

    LOG_DEBUG("Response: " + response.substr(0, 200));

    string translation = ParseGoogleFreeResponse(response);

    if (translation.empty()) {
        LOG_ERROR("Failed to parse Google Free response");
        result = "failed to parse Google Free response";
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }

    result = translation;
    SetLastError("");
    LOG_DEBUG("Translated: " + text.substr(0, 30) + " -> " + translation.substr(0, 50));
    return TranslationResult::SUCCESS;
}

// clients5.google.com/translate_a/t?client=dict-chrome-ex - the endpoint the
// official Google Dictionary Chrome extension uses. Deliberately omitting dt=t:
// without it the response is a plain 2-element array, ["translated text",
// "detected_source_lang"], instead of the more complex {"sentences":[...],
// "dict":[...]} object shape dt=t triggers on this endpoint - much less to parse
// and less to break if the shape drifts.
TranslationResult TranslationClient::TranslateWithDictChromeEx(const string& text, string& result,
                                                                const string& sourceLang, const string& targetLang) {
    string sl = MapLangCode(sourceLang);
    string tl = MapLangCode(targetLang);
    string path = "/translate_a/t?client=dict-chrome-ex&sl=" + sl + "&tl=" + tl + "&q=" + UrlEncode(text);

    vector<pair<string, string>> headers = {
        {"Accept", "*/*"},
        {"Accept-Language", "en-US,en;q=0.9"}
    };

    long statusCodeLong = 0;
    string error;
    string response = CurlHttpsGet("clients5.google.com", 443, path, headers, statusCodeLong, error);
    DWORD statusCode = static_cast<DWORD>(statusCodeLong);
    SetLastHttpStatus(statusCode);

    if (statusCode == 0) {
        result = error.empty() ? "network error" : error;
        SetLastError(result);
        return TranslationResult::NETWORK_ERROR;
    }
    if (statusCode == 429) {
        return TranslationResult::RATE_LIMITED;
    }
    if (statusCode == 403) {
        // Documented failure mode when the client param is missing/wrong.
        result = "dict-chrome-ex returned 403";
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }

    try {
        json parsed = json::parse(response);
        if (parsed.is_array() && !parsed.empty() && parsed[0].is_string()) {
            result = TrimCopy(parsed[0].get<string>());
            if (result.empty()) {
                result = "empty translation from dict-chrome-ex";
                SetLastError(result);
                return TranslationResult::API_ERROR;
            }
            SetLastError("");
            return TranslationResult::SUCCESS;
        }

        result = "unexpected dict-chrome-ex response shape";
        SetLastError(result);
        return TranslationResult::API_ERROR;
    } catch (const exception& e) {
        result = string("failed to parse dict-chrome-ex response: ") + e.what();
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }
}

string TranslationClient::MapLangCodeMicrosoft(const string& lang) {
    if (lang == "zh") return "zh-Hans";
    // en, ja, ko, ru are already valid Microsoft Translator language codes
    return lang;
}

// GET https://edge.microsoft.com/translate/auth returns a bearer token as plain
// text (not JSON-wrapped) - this is the same anonymous, keyless auth flow
// Microsoft Edge's built-in translate feature itself uses. Cached conservatively
// for 8 minutes (the documented Azure token lifetime for this flow is ~10
// minutes); a 401 on the actual translate call also drops the cache below so the
// next attempt fetches fresh rather than retrying the same stale token forever.
bool TranslationClient::GetEdgeAuthToken(string& outToken, string& outError) {
    {
        lock_guard<mutex> lock(edgeTokenMutex);
        if (!cachedEdgeToken.empty() && GetTickCount() < edgeTokenExpiresTick) {
            outToken = cachedEdgeToken;
            return true;
        }
    }

    vector<pair<string, string>> headers;  // no special headers needed for the auth call
    long statusCodeLong = 0;
    string response = CurlHttpsGet("edge.microsoft.com", 443, "/translate/auth", headers, statusCodeLong, outError);
    DWORD statusCode = static_cast<DWORD>(statusCodeLong);

    if (statusCode != 200 || response.empty()) {
        if (outError.empty()) {
            outError = "edge auth failed, HTTP " + to_string(statusCode);
        }
        return false;
    }

    string token = TrimCopy(response);
    if (token.empty()) {
        outError = "edge auth returned an empty token";
        return false;
    }

    {
        lock_guard<mutex> lock(edgeTokenMutex);
        cachedEdgeToken = token;
        edgeTokenExpiresTick = GetTickCount() + 8 * 60 * 1000;
    }

    outToken = token;
    return true;
}

// api.cognitive.microsofttranslator.com/translate?api-version=3.0 - the standard
// Microsoft Translator v3 REST API, authenticated with the anonymous token from
// GetEdgeAuthToken instead of a real Azure subscription key. This is the same
// flow Microsoft Edge's built-in page-translate feature uses.
TranslationResult TranslationClient::TranslateWithEdgeTranslate(const string& text, string& result,
                                                                 const string& sourceLang, const string& targetLang) {
    string token;
    string tokenError;
    if (!GetEdgeAuthToken(token, tokenError)) {
        result = "edge auth failed: " + tokenError;
        SetLastError(result);
        return TranslationResult::NETWORK_ERROR;
    }

    string sl = MapLangCodeMicrosoft(sourceLang);
    string tl = MapLangCodeMicrosoft(targetLang);
    string path = "/translate?from=" + sl + "&to=" + tl + "&api-version=3.0";

    json bodyArray = json::array();
    json textObj = json::object();
    textObj["Text"] = text;
    bodyArray.push_back(textObj);
    string body = bodyArray.dump(-1, ' ', false, json::error_handler_t::replace);

    vector<pair<string, string>> headers = {
        {"Authorization", "Bearer " + token},
        {"Content-Type", "application/json"}
    };

    long statusCodeLong = 0;
    string error;
    string response = CurlHttpsPost("api.cognitive.microsofttranslator.com", 443, path, body, headers, statusCodeLong, error);
    DWORD statusCode = static_cast<DWORD>(statusCodeLong);
    SetLastHttpStatus(statusCode);

    if (statusCode == 0) {
        result = error.empty() ? "network error" : error;
        SetLastError(result);
        return TranslationResult::NETWORK_ERROR;
    }
    if (statusCode == 401) {
        // Cached token was rejected - drop it so the NEXT attempt (next chain
        // call, or a later retry) fetches a fresh one instead of repeating this.
        lock_guard<mutex> lock(edgeTokenMutex);
        cachedEdgeToken.clear();
        result = "edge translate auth token rejected (401)";
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }
    if (statusCode == 429) {
        return TranslationResult::RATE_LIMITED;
    }

    try {
        json parsed = json::parse(response);
        // Expected shape: [{"translations":[{"text":"...","to":"en"}]}]
        if (parsed.is_array() && !parsed.empty() &&
            parsed[0].contains("translations") && parsed[0]["translations"].is_array() &&
            !parsed[0]["translations"].empty() &&
            parsed[0]["translations"][0].contains("text")) {
            result = TrimCopy(parsed[0]["translations"][0]["text"].get<string>());
            if (result.empty()) {
                result = "empty translation from edge translate";
                SetLastError(result);
                return TranslationResult::API_ERROR;
            }
            SetLastError("");
            return TranslationResult::SUCCESS;
        }

        result = "unexpected edge translate response shape";
        SetLastError(result);
        return TranslationResult::API_ERROR;
    } catch (const exception& e) {
        result = string("failed to parse edge translate response: ") + e.what();
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }
}

TranslationResult TranslationClient::TranslateWithCustom(const string& text, string& result,
                                                          const string& sourceLang, const string& targetLang) {
    string endpoint;
    string apiKey;
    string authHeader;
    string authScheme;
    string requestTemplate;
    string responsePath;

    {
        lock_guard<mutex> lock(configMutex);
        endpoint = customEndpoint;
        apiKey = customApiKey;
        authHeader = customAuthHeader;
        authScheme = customAuthScheme;
        requestTemplate = customRequestTemplate;
        responsePath = customResponsePath;
    }

    ParsedUrl url = ParseUrl(endpoint);
    if (!url.valid) {
        result = "Custom endpoint must be a valid HTTPS URL";
        SetLastError(result);
        return TranslationResult::INVALID_PARAMS;
    }

    string body = requestTemplate.empty()
        ? "{\"text\":\"{text}\",\"source\":\"{source}\",\"target\":\"{target}\"}"
        : requestTemplate;
    ReplaceAll(body, "{text}", JsonTemplateEscape(text));
    ReplaceAll(body, "{source}", JsonTemplateEscape(sourceLang));
    ReplaceAll(body, "{target}", JsonTemplateEscape(targetLang));

    vector<pair<string, string>> headers;
    if (!apiKey.empty() && !authHeader.empty()) {
        string headerValue;
        if (authScheme.empty() || ToLowerCopy(authScheme) == "none") {
            headerValue = apiKey;
        } else {
            headerValue = authScheme + " " + apiKey;
        }
        headers.push_back({authHeader, headerValue});
    }

    DWORD status = 0;
    string response = HttpsJsonRequest(url, body, headers, status);
    if (response.empty() && status == 0) {
        result = GetLastError().empty() ? "network error" : GetLastError();
        return TranslationResult::NETWORK_ERROR;
    }

    if (status == 429) {
        LOG_WARNING("Rate limited by custom endpoint (HTTP 429)");
        return TranslationResult::RATE_LIMITED;
    }

    try {
        json parsed = json::parse(response);
        if (status >= 400 || parsed.contains("error")) {
            result = JsonErrorMessage(parsed, status);
            SetLastError(result);
            LOG_ERROR("Custom provider error: " + result);
            return TranslationResult::API_ERROR;
        }

        if (!ExtractJsonPath(parsed, responsePath, result)) {
            result = "Custom response did not include path: " + responsePath;
            SetLastError(result);
            return TranslationResult::API_ERROR;
        }

        result = TrimCopy(result);
        SetLastError("");
        return TranslationResult::SUCCESS;
    } catch (const exception& e) {
        result = string("failed to parse custom response: ") + e.what();
        SetLastError(result);
        return TranslationResult::API_ERROR;
    }
}

TranslationResult TranslationClient::TranslateText(const string& text, string& result,
                                                    const string& sourceLang,
                                                    const string& targetLang) {
    if (!initialized) {
        result = "translator not initialized";
        SetLastError(result);
        return TranslationResult::INVALID_PARAMS;
    }
    if (text.empty()) {
        result = "empty text";
        return TranslationResult::INVALID_PARAMS;
    }

    TranslationProvider activeProvider;
    {
        lock_guard<mutex> lock(configMutex);
        activeProvider = provider;
    }

    // DLL-side cache check
    string cacheKey = GenerateCacheKey(text, sourceLang, targetLang);
    auto cacheIt = cache.find(cacheKey);
    if (cacheIt != cache.end() &&
        (GetTickCount() - cacheIt->second.timestamp) < CACHE_EXPIRY_MS) {
        result = cacheIt->second.translation;
        LOG_DEBUG("Cache hit: " + text.substr(0, 50));
        return TranslationResult::SUCCESS;
    }

    CleanExpiredCache();

    TranslationResult tr = (activeProvider == TranslationProvider::CUSTOM_HTTP)
        ? TranslateWithCustom(text, result, sourceLang, targetLang)
        : TranslateWithGoogleFree(text, result, sourceLang, targetLang);

    if (tr == TranslationResult::SUCCESS) {
        cache[cacheKey] = CacheEntry(result);
        LOG_DEBUG("Translation successful using provider: " + ProviderName(activeProvider));
    }

    return tr;
}

// Queue async translation request
bool TranslationClient::TranslateAsync(const string& requestId, const string& text,
                                       const string& sourceLang, const string& targetLang) {
    if (!initialized || !running) {
        return false;
    }

    lock_guard<mutex> lock(requestMutex);
    requestQueue.push(AsyncRequest(requestId, text, sourceLang, targetLang));
    LOG_DEBUG("Async request queued: " + requestId + " (" + sourceLang + " -> " + targetLang + ")");
    return true;
}

// Poll for completed translation
bool TranslationClient::PollResult(string& requestId, string& translation, string& error) {
    lock_guard<mutex> lock(resultMutex);

    if (resultQueue.empty()) {
        return false;
    }

    AsyncResult result = resultQueue.front();
    resultQueue.pop();

    requestId = result.requestId;
    translation = result.translation;
    error = result.error;

    return true;
}

// Get count of pending requests
size_t TranslationClient::GetPendingCount() {
    lock_guard<mutex> lock(requestMutex);
    return requestQueue.size();
}

// Worker thread for async translations
void TranslationClient::WorkerThreadFunc() {
    LOG_INFO("Worker thread started");

    while (running) {
        AsyncRequest request;
        bool hasRequest = false;

        {
            lock_guard<mutex> lock(requestMutex);
            if (!requestQueue.empty()) {
                request = requestQueue.front();
                requestQueue.pop();
                hasRequest = true;
            }
        }

        if (hasRequest) {
            LOG_DEBUG("Processing async request: " + request.requestId);

            string translation;
            string error;

            TranslationResult tr = TranslateText(request.text, translation,
                                                  request.sourceLang, request.targetLang);

            if (tr != TranslationResult::SUCCESS) {
                switch (tr) {
                    case TranslationResult::NETWORK_ERROR:  error = "network error"; break;
                    case TranslationResult::API_ERROR:      error = "API error";     break;
                    case TranslationResult::ENCODING_ERROR: error = "encoding error"; break;
                    case TranslationResult::TIMEOUT_ERROR:  error = "timeout";       break;
                    case TranslationResult::RATE_LIMITED:   error = "rate limited";  break;
                    default:                                error = "unknown error";  break;
                }
                translation = "";
            }

            {
                lock_guard<mutex> lock(resultMutex);
                resultQueue.push(AsyncResult(request.requestId, translation, error));
            }

            LOG_DEBUG("Async request completed: " + request.requestId);
        } else {
            Sleep(50);
        }
    }

    LOG_INFO("Worker thread stopped");
}
