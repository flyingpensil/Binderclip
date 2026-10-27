fetch('./deployment.json', {cache: 'no-store'})
  .then(response => { if (!response.ok) throw new Error('Workspace not configured'); return response.json(); })
  .then(config => {
    if (!config.appUrl) return;
    const app = new URL(config.appUrl);
    if (app.protocol !== 'https:' || app.username || app.password || app.search || app.hash || (app.pathname && app.pathname !== '/')) return;
    document.querySelectorAll('[data-app-link]').forEach(link => {
      link.href = `${app.origin}/login/`;
      link.hidden = false;
    });
    document.querySelector('#setup-status').hidden = true;
  })
  .catch(() => { /* Keep the honest setup state until a real server URL is configured. */ });
