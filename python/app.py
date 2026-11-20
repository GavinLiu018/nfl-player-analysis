"""NFL Player Rankings (2026) - Streamlit app.

Run: python/run.bat (Windows) or python/run.command (macOS/Linux). Or, from the project root:
    macOS/Linux:  .venv/bin/streamlit run python/app.py
    Windows:      .venv\\Scripts\\streamlit run python\\app.py
"""
import streamlit as st

st.set_page_config(page_title="NFL Player Rankings", page_icon=":material/sports_football:", layout="wide")

nav = st.navigation([
    st.Page("pages/rankings.py", title="Rankings", icon=":material/leaderboard:", default=True),
    st.Page("pages/model.py", title="Model", icon=":material/tune:"),
])
nav.run()
