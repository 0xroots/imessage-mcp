# Publishing checklist

1. Create the repository and push. Set the description to:
   `iMessage MCP server for macOS without Full Disk Access. Sandboxed, no network, you approve every connection and every message. Works with Claude Code, Codex and any MCP client.`
2. Add topics: `imessage`, `messages`, `mcp`, `mcp-server`, `model-context-protocol`, `macos`, `privacy`, `sandbox`, `claude-code`, `claude-code-plugin`, `codex`, `ai-agents`, `swift`, `no-full-disk-access`.
3. Render the site, commit `docs/`, and enable GitHub Pages from `main` and `/docs`:
   ```bash
   ./scripts/site.sh https://0xroots.github.io/<repo>/ https://github.com/0xroots/<repo>
   ```
4. Tag a release (for example `v0.2.0`) with release notes. Attach no binaries: builds are signed per user.
5. Verify the live URLs with GET requests: the page returns 200, the canonical matches, `robots.txt`, `sitemap.xml` and `llms.txt` load, and the JSON-LD parses.
6. Submit the sitemap in Google Search Console and Bing Webmaster Tools (requires your account). Submission is not indexing; check again after a few weeks.
7. Optional: notify IndexNow after deployment. Do not resubmit unchanged URLs.
8. Test the plugin in a clean session: `/plugin marketplace add 0xroots/<repo>` then `/plugin install imessage-mcp@imessage-mcp`.

`robots.txt` allows all crawlers. If you want to restrict model-training crawlers, decide that explicitly and add per-crawler groups.
