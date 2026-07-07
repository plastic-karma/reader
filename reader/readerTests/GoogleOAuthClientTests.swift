//
//  GoogleOAuthClientTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class GoogleOAuthClientTests: XCTestCase {

    private let clientID = "123-abc.apps.googleusercontent.com"

    // MARK: - PKCE

    func testPKCEMatchesRFC7636AppendixBVector() {
        let pkce = GoogleOAuthClient.PKCE(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsURLSafeAndUnique() {
        let first = GoogleOAuthClient.PKCE()
        let second = GoogleOAuthClient.PKCE()
        // 32 bytes → 43 unpadded base64url characters (RFC 7636 minimum 43).
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertTrue(first.verifier.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        })
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.verifier, first.challenge)
    }

    func testBase64URLEncodingUsesURLSafeAlphabetWithoutPadding() {
        // 0xFF 0xEF → standard base64 "/+8=" → url-safe "_-8".
        XCTAssertEqual(GoogleOAuthClient.base64URLEncoded(Data([0xFF, 0xEF])), "_-8")
    }

    // MARK: - Client ID → redirect scheme

    func testRedirectSchemeReversesValidClientID() {
        XCTAssertEqual(
            GoogleOAuthClient.redirectScheme(forClientID: clientID),
            "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(
            GoogleOAuthClient.redirectURI(forClientID: " \(clientID)\n"),
            "com.googleusercontent.apps.123-abc:/oauth2redirect",
            "Whitespace from a clipboard paste is tolerated")
    }

    func testRedirectSchemeRejectsMalformedIDs() {
        for bogus in [
            "",
            "not-a-client-id",
            ".apps.googleusercontent.com",
            "has space.apps.googleusercontent.com",
            "semi;colon.apps.googleusercontent.com",
        ] {
            XCTAssertNil(GoogleOAuthClient.redirectScheme(forClientID: bogus), bogus)
        }
    }

    // MARK: - Authorization URL + callback

    func testAuthorizationURLCarriesPKCEAndScope() throws {
        let pkce = GoogleOAuthClient.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try XCTUnwrap(GoogleOAuthClient.authorizationURL(
            clientID: clientID, pkce: pkce, state: "st4te"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], clientID)
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/gmail.modify")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "st4te")
    }

    func testAuthorizationURLIsNilForBadClientID() {
        XCTAssertNil(GoogleOAuthClient.authorizationURL(
            clientID: "junk", pkce: .init(), state: "s"))
    }

    private func callback(_ query: String) -> URL {
        URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?\(query)")!
    }

    func testCallbackParsingHappyPath() throws {
        XCTAssertEqual(
            try GoogleOAuthClient.authorizationCode(
                fromCallback: callback("code=abc123&state=st4te&scope=x"),
                expectedState: "st4te"),
            "abc123")
    }

    func testCallbackStateMismatchThrows() {
        XCTAssertThrowsError(try GoogleOAuthClient.authorizationCode(
            fromCallback: callback("code=abc&state=evil"), expectedState: "st4te")) { error in
            XCTAssertEqual(error as? GoogleOAuthClient.OAuthError, .stateMismatch)
        }
    }

    func testCallbackAccessDeniedIsUserCancelled() {
        XCTAssertThrowsError(try GoogleOAuthClient.authorizationCode(
            fromCallback: callback("error=access_denied&state=st4te"), expectedState: "st4te")) { error in
            XCTAssertEqual(error as? GoogleOAuthClient.OAuthError, .userCancelled)
        }
    }

    func testCallbackMissingCodeThrows() {
        XCTAssertThrowsError(try GoogleOAuthClient.authorizationCode(
            fromCallback: callback("state=st4te"), expectedState: "st4te")) { error in
            XCTAssertEqual(error as? GoogleOAuthClient.OAuthError, .missingCode)
        }
    }

    // MARK: - Token endpoint requests

    private func body(of request: URLRequest) -> String {
        request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func testTokenExchangeRequestIsSecretlessForm() {
        let request = GoogleOAuthClient.tokenExchangeRequest(
            clientID: clientID, code: "c0de", verifier: "v3rifier")

        XCTAssertEqual(request.url, GoogleOAuthClient.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded")
        let form = body(of: request)
        XCTAssertTrue(form.contains("client_id=\(clientID)"))
        XCTAssertTrue(form.contains("code=c0de"))
        XCTAssertTrue(form.contains("code_verifier=v3rifier"))
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("redirect_uri=com.googleusercontent.apps.123-abc:/oauth2redirect"))
        XCTAssertFalse(form.contains("client_secret"), "iOS-type clients have no secret")
    }

    func testRefreshRequestCarriesRefreshGrant() {
        let request = GoogleOAuthClient.refreshRequest(
            clientID: clientID, refreshToken: "rt-1")

        let form = body(of: request)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=rt-1"))
        XCTAssertTrue(form.contains("client_id=\(clientID)"))
        XCTAssertFalse(form.contains("client_secret"))
    }

    func testRevokeRequestPostsToken() {
        let request = GoogleOAuthClient.revokeRequest(token: "rt-1")
        XCTAssertEqual(request.url, GoogleOAuthClient.revocationEndpoint)
        XCTAssertEqual(body(of: request), "token=rt-1")
    }

    func testTokenResponseDecodesSnakeCase() throws {
        let json = #"{"access_token": "at", "expires_in": 3599, "refresh_token": "rt", "scope": "s", "token_type": "Bearer"}"#
        let decoded = try JSONDecoder().decode(
            GoogleOAuthClient.TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .init(accessToken: "at", expiresIn: 3599, refreshToken: "rt"))

        let refresh = #"{"access_token": "at2", "expires_in": 3599, "token_type": "Bearer"}"#
        let decodedRefresh = try JSONDecoder().decode(
            GoogleOAuthClient.TokenResponse.self, from: Data(refresh.utf8))
        XCTAssertNil(decodedRefresh.refreshToken, "Refreshes omit the refresh token")
    }
}
