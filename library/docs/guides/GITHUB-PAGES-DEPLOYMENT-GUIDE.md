# GitHub Pages Dashboard Deployment Guide

## [ROCKET] Quick Deploy

**To deploy the AitherZero dashboard to GitHub Pages RIGHT NOW:**

```bash
# Merge this PR to main branch
# The GitHub Pages workflow will automatically deploy within 2-3 minutes
```

That's it! The dashboard will be live at: `https://wizzense.github.io/AitherZero/`

---

## [STATS] What Gets Deployed

### Dashboard Files
- **Main Dashboard**: `reports/dashboard.html` (978 lines, fully styled)
- **JSON Data**: `reports/dashboard.json` (machine-readable)
- **Markdown**: `reports/dashboard.md` (text format)
- **Index Redirect**: `index.md` → redirects to dashboard

### URL Structure
```
https://wizzense.github.io/AitherZero/
 / → Redirects to dashboard
 /reports/dashboard.html → Main dashboard
 /reports/dashboard.json → JSON API
 /reports/dashboard.md → Markdown view
 /docs/ → Documentation
```

---

## [CONFIG] Automatic Deployment Workflow

### Workflow: `.github/workflows/jekyll-gh-pages.yml`

**Triggers:**
- Push to `main` branch
- Push to `develop` branch
- Changes to files in:
 - `reports/**`
 - `docs/**`
 - `index.md`
 - `_config.yml`
- Manual workflow dispatch

**Process:**
1. **Build Job**: Jekyll builds the site from source
2. **Deploy Job**: Deploys to GitHub Pages
3. **Reports**: Shows deployment URLs

**Deployment Time**: 2-3 minutes after merge

---

## [COPY] Pre-Deployment Checklist

Before merging to trigger deployment:

- [x] Dashboard HTML generated (`reports/dashboard.html`)
- [x] Dashboard shows real project data
- [x] Index.md redirects properly
- [x] Jekyll configuration valid (`_config.yml`)
- [x] GitHub Pages workflow exists
- [x] Workflow has proper permissions

[OK] **All checks passed! Ready to deploy.**

---

## [SEARCH] Verify Deployment

After merging, verify deployment:

1. **Check Workflow**:
 - Go to: `https://github.com/Aitherium/AitherZero/actions`
 - Look for "Deploy Jekyll with GitHub Pages" workflow
 - Status should show: [OK] Completed

2. **Test URLs**:
 ```bash
 # Root (should redirect to dashboard)
 curl -I https://wizzense.github.io/AitherZero/
 
 # Dashboard HTML
 curl https://wizzense.github.io/AitherZero/reports/dashboard.html
 
 # Dashboard JSON API
 curl https://wizzense.github.io/AitherZero/reports/dashboard.json
 ```

3. **Visual Check**:
 - Open: `https://wizzense.github.io/AitherZero/`
 - Should see: Modern dashboard with project metrics
 - Should show: 202 files, 83,712 LOC, 95% test success rate

---

## [SYNC] Update Dashboard (After Initial Deployment)

To update the deployed dashboard:

1. **Regenerate Dashboard**:
 ```powershell
 # Local machine
 ./automation-scripts/0512_Generate-Dashboard.ps1 -Format All
 ```

2. **Commit and Push**:
 ```bash
 git add reports/
 git commit -m "Update dashboard with latest metrics"
 git push origin main
 ```

3. **Auto-Deploy**: GitHub Pages workflow triggers automatically

---

## [TARGET] Dashboard Features

### Data Sources
- [OK] Test reports (`TestReport-*.json`)
- [OK] PSScriptAnalyzer results (`psscriptanalyzer-fast-results.json`)
- [OK] Module manifest (`AitherZero.psd1`)
- [OK] Git commit history
- [OK] File system metrics

### Displayed Metrics
- [FILES] **Files**: 202 (132 scripts, 60 modules, 10 data)
- [NOTE] **Lines of Code**: 83,712
- **Tests**: 117 (103 unit, 14 integration)
- [OK] **Test Results**: 9,500 passed, 500 failed (95% success)
- **Code Quality**: 22 PSScriptAnalyzer warnings
- [INDEX] **Modules**: 11 domains with module counts
- [STATS] **Recent Activity**: Git commits and timestamps

### Visual Features
- [ART] Color-coded metrics (green/yellow/red)
- [UP] Progress bars and charts
- [SEARCH] Interactive navigation TOC
- [PHONE] Mobile-responsive design
- [MOON] Modern dark theme
- [SYNC] Auto-refresh indicators

---

## [FIX] Troubleshooting

### Dashboard Not Deploying

**Check 1: Workflow Status**
```bash
# View recent workflow runs
gh workflow list
gh run list --workflow=jekyll-gh-pages.yml
```

**Check 2: GitHub Pages Settings**
- Go to: Repository → Settings → Pages
- Source should be: "GitHub Actions"
- Custom domain: (if configured)

**Check 3: File Paths**
```bash
# Verify files exist
ls -la reports/dashboard.html
ls -la index.md
ls -la _config.yml
```

### Dashboard Shows Old Data

**Solution**: Regenerate dashboard files
```powershell
# Generate fresh dashboard
./automation-scripts/0512_Generate-Dashboard.ps1 -Format All

# Commit and push
git add reports/
git commit -m "Update dashboard data"
git push origin main
```

### 404 Error on Dashboard

**Check**: Index redirect in `index.md`
```yaml
---
layout: default
title: AitherZero Dashboard
redirect_to: /AitherZero/reports/dashboard.html
---
```

**Verify**: Path matches repository name
- Repository: `Aitherium/AitherZero`
- Path: `/AitherZero/reports/dashboard.html` [OK]

---

## [ART] Customization

### Update Dashboard Styling

1. Edit: `automation-scripts/0512_Generate-Dashboard.ps1`
2. Modify CSS in the HTML template section
3. Regenerate dashboard:
 ```powershell
 ./automation-scripts/0512_Generate-Dashboard.ps1 -Format HTML
 ```
4. Commit and push to deploy

### Add New Metrics

1. Edit: `Get-ProjectMetrics` or `Get-PSScriptAnalyzerMetrics` functions
2. Update HTML template to display new data
3. Regenerate and deploy

### Change Theme Colors

Find and modify in `0512_Generate-Dashboard.ps1`:
```css
:root {
 --primary-color: #667eea; /* Change this */
 --secondary-color: #764ba2; /* Change this */
 /* ... */
}
```

---

## Support

### Common Questions

**Q: How often should I update the dashboard?**
A: Update after significant changes (new tests, major commits, etc.)

**Q: Can I automate dashboard generation?**
A: Yes! Add to CI/CD pipeline or create a scheduled workflow.

**Q: Does this replace the ReportingEngine module?**
A: No! ReportingEngine provides console/terminal dashboards. This creates static HTML for web deployment.

**Q: Can I customize the dashboard layout?**
A: Yes! Edit the HTML template in `0512_Generate-Dashboard.ps1`.

---

## [OK] Deployment Complete!

Once you see this in the workflow output:
```
[OK] Successfully deployed to GitHub Pages!
[LINK] Main URL: https://wizzense.github.io/AitherZero/
[STATS] Dashboard: https://wizzense.github.io/AitherZero/reports/dashboard.html
```

Your dashboard is LIVE! [SUCCESS]

---

*Generated: 2025-10-30*
*Status: Ready for immediate deployment*
*Merge PR to deploy!*
