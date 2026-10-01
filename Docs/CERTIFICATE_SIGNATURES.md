# Certificate PDF signatures

Annotate creates detached SHA-256 certificate approval signatures and validates original signed PDF bytes. This is distinct from the visible typed, drawn, or uploaded signature placed on a page. The certificate field has an invisible widget; place a visible signature first if desired, then use **Sign a copy…** to protect the finished document.

## Interaction and identity safety

The Sign panel exposes certificate signing and validation alongside visible signatures. **Load identities from Keychain** is the only identity-enumeration action. Nothing loads on appearance, no identity is preselected, and reloading clears the selection. The picker includes a fingerprint suffix to distinguish certificates with the same subject; the complete SHA-256 fingerprint is available for inspection. **Sign a copy…** explicitly authorizes the selected identity's private-key operation. Security may present its normal Keychain access prompt. The application does not export private keys or store certificate passwords.

The signed bytes are independently checked by the native validator before the save panel appears. They are written directly and atomically, without passing back through PDFKit serialization. The existing source-overwrite guard protects the open document. Signing does not change the document or its undo history.

**Validate a signed PDF…** reads the chosen file's exact bytes. Reserializing a PDF before validation would invalidate its signature, so validation does not use the open reader's PDFKit representation. Results show byte integrity, the certificate subject (as claimed), certificate trust, whole-file coverage, and expandable details with each signer certificate's issuer (as claimed) and SHA-256 fingerprint. No green verified state is shown for an untrusted certificate, a certificate not issued for signing documents, or unsigned appended bytes.

Names in a result come from the PDF and its certificates, so `UntrustedText.display` prepares them for one line: control and format characters (line breaks, bidirectional embeddings, overrides and isolates, zero-width characters) are removed, whitespace runs become single spaces, and long names end in an ellipsis. A crafted name cannot add a line, reorder the text around it, or imitate the status.

## Format and verification

`PDFCertificateSignature` preserves the reachable catalog, page tree, original content streams, existing annotations, and AcroForm fields using the native object graph writer. It adds a `/Sig` dictionary with `/Adobe.PPKLite`, `/adbe.pkcs7.detached`, a reachable `/FT /Sig` field, and a zero-size widget. A fixed 32 KiB Contents reservation and fixed-width ByteRange reservation are finalized before hashing. The CMS signature covers every output byte except the complete hexadecimal Contents token; insertion preserves all offsets.

Apple CMSEncoder supplies detached signing, the SHA-256 digest, signing-time attributes, and certificate-chain embedding. The observed encoder emits indefinite-length BER containers. The bounded native `PDFCertificateDER` conversion writes definite lengths and canonical SET order before PDF embedding; native CMS and independent OpenSSL tests verify that the signed attributes still authenticate correctly. This conversion operates only on native encoder output.

Validation finds reachable signature fields and catalog permission signatures. It requires four nonnegative ByteRange integers starting at zero, in-bounds ordered ranges, and an excluded hexadecimal token exactly matching Contents. The DER envelope must fit inside Contents with only zero padding. Before calling Security, a structural inspection requires detached SignedData with the `id-data` content type and no embedded content. Attached or encrypted CMS cannot authenticate unrelated PDF bytes or trigger a decryption key lookup. Security checks every CMS signer, with signature verification separated from certificate trust evaluation.

Trust uses the Mac's certificate store and Basic X.509 policy at the current date, explicitly disabling network certificate fetching.

A chain to a trusted root proves who issued a certificate, not what for: a web server's TLS certificate chains to a trusted root too. So a signer certificate counts as **trusted** only when its chain is trusted and its usage covers signing documents (`PDFCertificateUsage`):

- the extended key usage extension is absent (unrestricted, per RFC 5280), or names at least one of id-kp-documentSigning `1.3.6.1.5.5.7.3.36`, emailProtection `1.3.6.1.5.5.7.3.4`, Microsoft document signing `1.3.6.1.4.1.311.10.3.12`, Adobe Authentic Documents Trust `1.2.840.113583.1.1.5`, or anyExtendedKeyUsage `2.5.29.37.0`; and
- the key usage extension, if present, allows digitalSignature or nonRepudiation (contentCommitment).

When the chain is trusted but the usage doesn't qualify, the result is **certificate not issued for signing documents**: the certificate chains to a root this Mac trusts, but it wasn't issued for signing documents. `PDFCertificateX509` reads the extensions with the bounded DER reader; a malformed, empty, or repeated usage extension fails closed into the same state. An untrusted chain is reported first, ahead of usage. A signer-supplied signing time is not a trusted timestamp and does not override current-date trust evaluation. Disposable test anchors are passed to an internal test overload only; production never installs trust anchors. Additional bytes after the signed revision are reported as changes after signing even when the earlier signature remains cryptographically intact.

## Explicit limits

- Maximum input/output PDF size: 256 MiB; CMS envelope: 1 MiB; field traversal: 10,000 nodes and 64 levels. Oversized certificate chains fail before output is saved. Signing reasons are limited to 2,000 UTF-8 bytes.
- Signing rejects locked, restricted, encrypted, or already-signed documents. Full graph rewriting cannot preserve an earlier signature, so incremental co-signing is unavailable. Encryption is never removed automatically.
- Validation supports `adbe.pkcs7.detached`. Other subfilters are identified as unsupported. Encrypted-file validation is unavailable.
- This is an approval signature, without DocMDP change-policy certification, online revocation checking, RFC 3161 timestamps, PAdES archival profiles, or long-term validation. An intact signature proves byte integrity relative to its included certificate; trust and legal identity are separate questions.
- Editing or saving a signed PDF through a normal PDF editor can invalidate its signature. Appended revisions are disclosed without claiming that their changes are permitted or harmless.

## Verification

`CertificateSignatureTests` uses a freshly generated disposable RSA identity imported with `kSecImportToMemoryOnly`. The identity and private key are never added to Keychain. Temporary private-key, certificate, and PKCS#12 fixtures are removed after each test. Only test code invokes `/usr/bin/openssl`; the shipped app has no runtime process or third-party crypto dependency.

The suite verifies detached SHA-256 CMS, self-signed/untrusted status, explicit in-memory test-anchor trust, the signing-usage rule against anchored certificates issued with OpenSSL `-addext` usage extensions (server-only and key-encipherment-only certificates are not trusted for signing; unrestricted, email protection, and document signing certificates are), an independently computed SHA-256 fingerprint, save/reopen preservation of text and forms, source nonmutation, and independent OpenSSL verification of separately extracted ByteRange content. Altered signed bytes fail both verifiers; appended bytes produce an explicit coverage warning. Re-signing, malformed ranges, unsupported subfilters, encryption, attached CMS, encrypted CMS, and empty input fail clearly. `CertificateUsageTests` covers the usage rule, OID decoding, and hand-built certificates with repeated, empty, malformed, and truncated extensions. `CertificateUntrustedTextTests` covers bidirectional, line-break, zero-width, and truncation cases. ASN.1 tests cover nested indefinite containers, long lengths, truncated values, primitive indefinite lengths, trailing data, and excessive nesting. Existing visible-signature tests remain part of the focused run.

The opt-in `ANNOTATE_CERTIFICATE_SMOKE_OUTPUT=1` exports only the synthetic signed guide and its public certificate to `build/Certificate-Validation-Smoke.pdf` for installed-app validation. Its disposable private key is erased with the temporary test fixture.

The focused `CertificateSignatureTests|CertificateDERTests|SignatureTests` run passed 12 test functions across 3 suites in 1.820 seconds. This proves the native and independent fixture checks; installed-app validation and release build/install evidence are recorded separately by the release verification workflow.

## Primary references

Eight primary references were used, with API contracts additionally checked against Apple's shipped `CMSEncoder.h`, `CMSDecoder.h`, and `SecImportExport.h` SDK headers:

1. [ISO 32000-1:2008, section 12.8 and Table 252](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf): PDF signature dictionaries, Contents, ByteRange, and detached signatures.
2. [Adobe supported signature standards](https://www.adobe.com/devnet-docs/acrobatetk/tools/DigSigDC/standards.html): SHA-256 and PKCS#7 signature support.
3. [Apple CMSEncoderSetSignerAlgorithm](https://developer.apple.com/documentation/security/cmsencodersetsigneralgorithm(_:_:)): explicit SHA-256 digest selection.
4. [Apple CMSDecoderCopySignerStatus](https://developer.apple.com/documentation/security/cmsdecodercopysignerstatus(_:_:_:_:_:_:_:)): separate cryptographic status and caller-controlled trust evaluation.
5. [Apple SecTrustSetNetworkFetchAllowed](https://developer.apple.com/documentation/security/sectrustsetnetworkfetchallowed(_:_:)): offline certificate evaluation.
6. [Apple SecTrustSetVerifyDate](https://developer.apple.com/documentation/security/sectrustsetverifydate(_:_:)): explicit current-date evaluation.
7. [Apple kSecImportToMemoryOnly](https://developer.apple.com/documentation/security/ksecimporttomemoryonly): macOS in-memory PKCS#12 fixture import.
8. [Apple CMSEncoderCopyEncodedContent](https://developer.apple.com/documentation/security/cmsencodercopyencodedcontent(_:_:)): final native CMS output.
