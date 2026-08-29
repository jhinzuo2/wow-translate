// wininet_bridge.cpp - a single HTTPS GET via WinINet, kept in its own translation
// unit and never compiled alongside winhttp.h (see wininet_bridge.h for why).

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <wininet.h>
#include <string>
#include <vector>
#include <utility>
#include <algorithm>

#include "../include/wininet_bridge.h"
#include "../include/logging.h"

using namespace std;

namespace {

string PreviewBody(const string& body, size_t maxLen = 400) {
    string preview = body.substr(0, min(body.length(), maxLen));
    size_t pos = 0;
    while ((pos = preview.find("\r\n", pos)) != string::npos) {
        preview.replace(pos, 2, " | ");
        pos += 3;
    }
    if (body.length() > maxLen) {
        preview += "... (" + to_string(body.length()) + " bytes total)";
    }
    return preview;
}

string QueryRawHeaders(HINTERNET hRequest) {
    DWORD size = 0;
    HttpQueryInfoA(hRequest, HTTP_QUERY_RAW_HEADERS_CRLF, nullptr, &size, nullptr);
    if (size == 0) {
        return "";
    }

    string buffer(size, '\0');
    if (!HttpQueryInfoA(hRequest, HTTP_QUERY_RAW_HEADERS_CRLF,
                        &buffer[0], &size, nullptr)) {
        return "";
    }
    // size includes a trailing NUL after the last header line
    return string(buffer.c_str());
}

} // namespace

string WinInetHttpsGet(const string& host, int port, const string& pathAndQuery,
                       const vector<pair<string, string>>& headers,
                       DWORD& statusCode, string& outError) {
    statusCode = 0;
    outError.clear();

    // The User-Agent set here becomes the request's default User-Agent header,
    // same as what worked in the PowerShell Invoke-WebRequest test.
    HINTERNET hInet = InternetOpenA(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        INTERNET_OPEN_TYPE_PRECONFIG,
        nullptr, nullptr, 0);
    if (!hInet) {
        outError = "InternetOpenA failed (" + to_string(GetLastError()) + ")";
        LOG_ERROR("WinINet: " + outError);
        return "";
    }

    // 8-second timeouts, matching the WinHTTP path's fail-fast behavior.
    DWORD timeoutMs = 8000;
    InternetSetOptionA(hInet, INTERNET_OPTION_CONNECT_TIMEOUT, &timeoutMs, sizeof(timeoutMs));
    InternetSetOptionA(hInet, INTERNET_OPTION_SEND_TIMEOUT, &timeoutMs, sizeof(timeoutMs));
    InternetSetOptionA(hInet, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeoutMs, sizeof(timeoutMs));

    HINTERNET hConnect = InternetConnectA(hInet, host.c_str(),
                                          static_cast<INTERNET_PORT>(port),
                                          nullptr, nullptr,
                                          INTERNET_SERVICE_HTTP, 0, 0);
    if (!hConnect) {
        outError = "InternetConnectA failed (" + to_string(GetLastError()) + ")";
        LOG_ERROR("WinINet: " + outError);
        InternetCloseHandle(hInet);
        return "";
    }

    DWORD flags = INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE;
    HINTERNET hRequest = HttpOpenRequestA(hConnect, "GET", pathAndQuery.c_str(),
                                          nullptr, nullptr, nullptr, flags, 0);
    if (!hRequest) {
        outError = "HttpOpenRequestA failed (" + to_string(GetLastError()) + ")";
        LOG_ERROR("WinINet: " + outError);
        InternetCloseHandle(hConnect);
        InternetCloseHandle(hInet);
        return "";
    }

    string headerBlock;
    for (const auto& header : headers) {
        if (!header.first.empty() && !header.second.empty()) {
            headerBlock += header.first + ": " + header.second + "\r\n";
        }
    }

    LOG_DEBUG("WinINet GET https://" + host + ":" + to_string(port) + pathAndQuery);
    if (!headerBlock.empty()) {
        LOG_DEBUG("WinINet request headers: " + headerBlock);
    }

    BOOL sent = HttpSendRequestA(hRequest,
                                 headerBlock.empty() ? nullptr : headerBlock.c_str(),
                                 headerBlock.empty() ? 0 : static_cast<DWORD>(headerBlock.length()),
                                 nullptr, 0);

    string response;
    if (sent) {
        DWORD statusSize = sizeof(statusCode);
        HttpQueryInfoA(hRequest, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                      &statusCode, &statusSize, nullptr);

        char buffer[8192];
        DWORD bytesRead = 0;
        while (InternetReadFile(hRequest, buffer, sizeof(buffer), &bytesRead) && bytesRead > 0) {
            response.append(buffer, bytesRead);
        }

        if (statusCode != 200) {
            LOG_WARNING("WinINet response status: " + to_string(statusCode));
            LOG_WARNING("WinINet response headers: " + QueryRawHeaders(hRequest));
            LOG_WARNING("WinINet response body: " + PreviewBody(response));
        } else {
            LOG_DEBUG("WinINet response status: 200, " + to_string(response.length()) + " bytes");
        }
    } else {
        outError = "HttpSendRequestA failed (" + to_string(GetLastError()) + ")";
        LOG_ERROR("WinINet: " + outError);
    }

    InternetCloseHandle(hRequest);
    InternetCloseHandle(hConnect);
    InternetCloseHandle(hInet);
    return response;
}
