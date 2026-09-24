# Appats Model Tracker

An interactive chart of AI models' intelligence against cost per task, filtered by Appats' requirements: Spanish and Catalan support, a GDPR Art. 28 DPA, processing in the EU/EEA, no training on Appats' data, no data kept by the host, and tool calling for escalation to a person. The page is `index.html`; its link is under **Settings → Pages**.

## How it stays current

Every morning at 05:00 UTC, the **Refresh tracker** job (Actions tab) fetches live prices and rebuilds `index.html`, and GitHub Pages publishes it a minute later. To update it straight away, open the Actions tab, choose **Refresh tracker** and press **Run workflow**. If a source is down, the job fails and the page keeps the last good data.

## Updating the requirements data

Edit these files here on GitHub (pencil icon, then **Commit changes**); the page rebuilds within a few minutes:

* `live_chart/hosts.csv`: each host's DPA status and source.
* `live_chart/languages.csv`: which makers name Spanish and Catalan as supported languages.
* `live_chart/appats_tests.csv`: Appats' own test results, one row per model, as `model,spanish,catalan,tested_on,notes` with `pass` or `fail`.

## Sources

Artificial Analysis (models and API providers leaderboards), OpenRouter (models, EU list and provider data policies), Cheaper Inference (markets) and each host's DPA page. Artificial Analysis data is shown with attribution, as its terms require.
