// The page's language: the one picked before on this site, else the browser's (Portuguese or English). Every text is
// in the page twice (lang="en" / lang="pt-BR"); the stylesheet shows the html element's language only.
(function () {
  var pick = null;
  try { pick = localStorage.getItem('pier-lang'); } catch (e) {}
  if (pick !== 'pt-BR' && pick !== 'en') pick = /^pt\b/i.test(navigator.language || '') ? 'pt-BR' : 'en';
  var root = document.documentElement;
  function apply(lang) {
    root.lang = lang;
    var title = root.getAttribute(lang === 'en' ? 'data-title-en' : 'data-title-pt');
    if (title) document.title = title;
    document.querySelectorAll('.lang button').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-lang') === lang));
    });
  }
  apply(pick);
  document.addEventListener('DOMContentLoaded', function () {
    apply(root.lang);
    document.querySelectorAll('.lang button').forEach(function (b) {
      b.addEventListener('click', function () {
        var lang = b.getAttribute('data-lang');
        try { localStorage.setItem('pier-lang', lang); } catch (e) {}
        apply(lang);
      });
    });
  });
})();
