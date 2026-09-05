# Security policy

## Supported versions

Security fixes are developed on the current `main` branch. Please reproduce a suspected issue with the latest code when practical and include the affected app version or commit. Older builds are not maintained as separate security-update branches; update to the latest fixed version when one is available.

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting form for Annotate](https://github.com/mweingartner/annotate/security/advisories/new). You can also open the repository's **Security → Advisories** page and choose **Report a vulnerability**. A GitHub account is required.

Please do not disclose a suspected vulnerability, exploit, or sensitive document in a public issue, discussion, or pull request. Ordinary bugs and feature requests can use [public issues](https://github.com/mweingartner/annotate/issues).

Include what you can:

- Annotate version or commit, macOS version, and Mac architecture.
- Steps to reproduce, expected behavior, and actual behavior.
- The potential security impact and any prerequisites.
- A minimal PDF or other proof of concept, relevant logs, and screenshots if helpful.

Use a synthetic or redacted test document whenever possible. Remove passwords, tokens, personal information, and unrelated document content before sharing a report. Test only with files and systems you are authorized to use.

If the private form is unavailable, open a public issue asking for a private reporting channel **without including vulnerability details or attachments**.

## Handling reports

Reports are reviewed on a best-effort basis; there is no guaranteed response or resolution time. Maintainers may request more information to reproduce and assess the issue. Confirmed issues can be coordinated through the private advisory while a fix and disclosure are prepared. Please discuss publication timing there before making technical details public. Reporter credit can be coordinated in the advisory.

Relevant reports include unsafe handling of PDFs or embedded annotation metadata, unauthorized file access, and unintended disclosure of document content through saving, printing, or exporting. Annotate uses Apple's PDFKit and other system frameworks; a report may require coordination with the upstream framework provider.
