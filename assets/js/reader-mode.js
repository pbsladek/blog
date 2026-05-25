(function () {
  var STORAGE_KEY = "pbsladek.blog.readerMode";

  function storedPreference() {
    try {
      return window.localStorage.getItem(STORAGE_KEY) === "true";
    } catch (error) {
      return false;
    }
  }

  function storePreference(enabled) {
    try {
      window.localStorage.setItem(STORAGE_KEY, enabled ? "true" : "false");
    } catch (error) {
      return;
    }
  }

  function setReaderMode(button, enabled) {
    document.body.classList.toggle("reader-mode", enabled);
    button.setAttribute("aria-pressed", enabled ? "true" : "false");
    button.querySelector(".reader-mode-toggle__label").textContent = enabled ? "Standard" : "Reader";
    storePreference(enabled);
  }

  function createToggle() {
    var button = document.createElement("button");
    button.className = "reader-mode-toggle";
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.setAttribute("aria-label", "Toggle reader mode");
    button.innerHTML = '<i class="fas fa-book-open" aria-hidden="true"></i><span class="reader-mode-toggle__label">Reader</span>';
    return button;
  }

  document.addEventListener("DOMContentLoaded", function () {
    if (!document.querySelector(".page__content")) return;

    var button = createToggle();
    document.body.appendChild(button);
    setReaderMode(button, storedPreference());

    button.addEventListener("click", function () {
      setReaderMode(button, !document.body.classList.contains("reader-mode"));
    });
  });
}());
