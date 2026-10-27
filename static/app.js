document.querySelector('.menu-button')?.addEventListener('click', () => document.body.classList.toggle('nav-open'));
document.querySelectorAll('[data-print]').forEach(button => button.addEventListener('click', () => window.print()));
document.addEventListener('keydown', event => {
  if (event.key === '/' && !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName)) {
    event.preventDefault(); document.querySelector('.global-search input')?.focus();
  }
});
document.querySelectorAll('[data-auto-search]').forEach(input => {
  let timeout;
  input.addEventListener('input', () => {
    clearTimeout(timeout);
    timeout = setTimeout(() => { if (!input.composing) input.form.requestSubmit(); }, 650);
  });
});
// Keep a deliberate submit for financial actions; disable duplicate clicks after validation.
document.querySelectorAll('form[method="post"]').forEach(form => form.addEventListener('submit', () => {
  form.querySelectorAll('button').forEach(button => { button.disabled = true; });
}));
