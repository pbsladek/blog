(function () {
  var STORAGE_KEY = "pbsladek.blog.theme";

  function storedTheme() {
    try {
      return window.localStorage.getItem(STORAGE_KEY) === "light" ? "light" : "dark";
    } catch (error) {
      return "dark";
    }
  }

  function storeTheme(theme) {
    try {
      window.localStorage.setItem(STORAGE_KEY, theme);
    } catch (error) {
      return;
    }
  }

  function setTheme(button, theme) {
    var isLight = theme === "light";
    document.documentElement.setAttribute("data-theme", isLight ? "light" : "dark");
    button.setAttribute("aria-pressed", isLight ? "true" : "false");
    button.querySelector(".theme-toggle__icon").className = isLight ? "fas fa-moon theme-toggle__icon" : "fas fa-sun theme-toggle__icon";
    button.querySelector(".theme-toggle__label").textContent = isLight ? "Dark" : "Light";
    storeTheme(isLight ? "light" : "dark");
  }

  function createToggle() {
    var button = document.createElement("button");
    button.className = "theme-toggle";
    button.type = "button";
    button.setAttribute("aria-pressed", "false");
    button.setAttribute("aria-label", "Toggle light and dark theme");
    button.innerHTML = '<i class="fas fa-sun theme-toggle__icon" aria-hidden="true"></i><span class="theme-toggle__label">Light</span>';
    return button;
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = createToggle();
    document.body.appendChild(button);
    setTheme(button, storedTheme());

    button.addEventListener("click", function () {
      var nextTheme = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
      setTheme(button, nextTheme);
    });
  });
}());
