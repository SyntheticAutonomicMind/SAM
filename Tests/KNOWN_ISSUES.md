# MCP Test Suite - Known Issues and Improvements

## Issues Found During Testing

### 1. Working Directory Not Being Respected
**Problem:** Tests are failing when working in directories outside the main repo.  
**Expected:** Passing working directory via API should allow operations in that directory.  
**Status:** Needs investigation - may be a bug in SAM's API handling.

**Test Command:**
```bash
cd tests && ./mcp_api_tests.sh
```

**Failures:**
- file_operations.grep_search
- file_operations.file_search
- file_operations.create_file (all levels)
- terminal_operations.create_directory

**Fix Required:**
- API should accept `workingDirectory` parameter
- File operations should respect working directory from API
- Or: Run tests from SAM repo root with absolute paths

### 2. Terminal Operations Disabled by Default
**Problem:** Terminal operations fail for new conversations.  
**Expected:** Terminal tools should work when explicitly enabled.  
**Status:** By design - security feature.

**Error Pattern:**
- terminal_operations.create_directory: fails
- terminal_operations.run_command: fails for some operations

**Fix Required:**
- Add `enableTerminal: true` parameter to API requests for terminal tests
- Or: Document that terminal operations require explicit enablement
- Or: Pre-configure test conversation to allow terminal operations

### 3. Authorization Issues for Write Operations
**Problem:** File write/modify/delete operations failing.  
**Root Cause:** Security-scoped bookmarks not granted for test workspace.

**Failing Operations:**
- file_operations.create_file
- file_operations.replace_string  
- file_operations.rename_file
- file_operations.delete_file

**Fix Required:**
- Grant security-scoped bookmark for test_workspace directory
- Or: Run tests within already-authorized directory (SAM repo)
- Or: Add bookmark granting to test setup

### 4. Search Operations Failing
**Problem:** grep_search and file_search not finding results.  
**Possible Causes:**
- Working directory not being set correctly
- Search scope not including test_workspace
- Glob patterns not resolving correctly

**Fix Required:**
- Pass absolute paths to search operations
- Verify glob pattern resolution
- Check search scope configuration

## Recommended Fixes

### Quick Fix (Short Term)
1. **Run tests from SAM repo root:**
   ```bash
   cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM
   ./tests/mcp_api_tests.sh
   ```

2. **Update test paths to be absolute:**
   - Already using absolute paths for most operations
   - Ensure search patterns include full paths

3. **Enable terminal operations:**
   - Add to API requests: `"enableTerminal": true`
   - Or document terminal requirement

### Proper Fix (Long Term)
1. **Add working directory support to API:**
   ```json
   {
     "model": "gpt-4",
     "messages": [...],
     "workingDirectory": "/path/to/working/dir"
   }
   ```

2. **Auto-grant authorization for paths in working directory:**
   - If workingDirectory specified, grant security bookmark
   - Or: Return authorization prompt to user
   - Or: Add to authorized paths list

3. **Terminal enablement via API:**
   ```json
   {
     "model": "gpt-4",
     "messages": [...],
     "enabledTools": ["terminal_operations"]
   }
   ```

## Test Suite Improvements

### Coverage Improvements
- [ ] Add more web operation tests (scrape, research)
- [ ] Add document creation tests
- [ ] Add multi-file operation tests
- [ ] Add error handling tests
- [ ] Add concurrent operation tests

### Robustness Improvements
- [ ] Better error detection (check API response for errors)
- [ ] Timeout handling for long-running operations
- [ ] Retry logic for transient failures
- [ ] More comprehensive assertions

### Setup Improvements
- [ ] Auto-detect working directory
- [ ] Auto-request authorization if needed
- [ ] Setup script to prepare test environment
- [ ] Cleanup script to remove test artifacts

## Current Workarounds

### For File Operations
```bash
# Run from repo root with absolute paths
cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM
./tests/mcp_api_tests.sh
```

### For Terminal Operations
```bash
# Enable terminal in SAM UI first, or add to API:
{
  "enabledTools": ["terminal_operations"]
}
```

### For Authorization
```bash
# Grant access via SAM UI before running tests
# Or: Run tests within SAM repo (already authorized)
```

## Success Metrics

**Current Status:**
- 18/49 tests passing (36.7%)
- All read operations working
- Memory, web, document ops working
- Version control ops working

**Target Status (After Fixes):**
- 40+/49 tests passing (80%+)
- All file operations working
- Terminal operations working (when enabled)
- Full directory hierarchy validated

## Next Steps

1. Document workarounds in README
2. Create GitHub issues for API improvements
3. Move to Priority 2 (prompt scoping)
4. Return to test suite after API enhancements

---

**Created:** November 17, 2025  
**Last Updated:** November 17, 2025  
**Status:** Active - Awaiting API enhancements
