# Appats Model Tracker

An interactive chart of AI models' intelligence against cost per task, filtered by Appats' requirements: Spanish and Catalan support, a GDPR Art. 28 DPA, processing in the EU/EEA, no training on Appats' data, no data kept by the host, and tool calling for escalation to a person. A Score card ranks the models that meet them by weights you set for each requirement plus intelligence, cost and environmental footprint. The page is `index.html`; its link is under **Settings → Pages**.

## How it stays current

Every morning at 05:00 UTC, the **Refresh tracker** job (Actions tab) fetches live prices and rebuilds `index.html`, and GitHub Pages publishes it a minute later. To update it straight away, open the Actions tab, choose **Refresh tracker** and press **Run workflow**. If a source is down, the job fails and the page keeps the last good data.

## Updating the requirements data

Edit these files here on GitHub (pencil icon, then **Commit changes**); the page rebuilds within a few minutes:

* `live_chart/hosts.csv`: each host's DPA status and source.
* `live_chart/languages.csv`: which makers name Spanish and Catalan as supported languages.
* `live_chart/appats_tests.csv`: Appats' own test results, one row per model, as `model,spanish,catalan,tested_on,notes` with `pass` or `fail`.
* `live_chart/catalan_tests_map.csv`: which of Softcatalà's tested models each tracker model is, as `softcatala_model,tracker_match,note` (`tracker_match` is a regular expression on the tracker's model name). Their scores are shown in model details only.

## Sources

Artificial Analysis (models and API providers leaderboards, plus one model page for model sizes, output tokens per task and the release dates the leaderboard leaves out), OpenRouter (models, EU list and provider data policies), Cheaper Inference (markets), Softcatalà's Catalan tests (only the few numbers shown, with credit and a link; their repository has no licence file) and each host's DPA page. Artificial Analysis data is shown with attribution, as its terms require.
