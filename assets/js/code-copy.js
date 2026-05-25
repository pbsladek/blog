(function () {
  function getLanguage(block) {
    var className = block.className || "";
    var match = className.match(/language-([^\s]+)/);
    if (!match) return "code";
    return match[1].replace(/^plaintext$/, "text");
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }

    return new Promise(function (resolve, reject) {
      var textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.top = "-9999px";
      document.body.appendChild(textarea);
      textarea.select();

      try {
        document.execCommand("copy") ? resolve() : reject(new Error("Copy failed"));
      } catch (error) {
        reject(error);
      } finally {
        document.body.removeChild(textarea);
      }
    });
  }

  function enhanceCodeBlock(block) {
    if (block.classList.contains("code-block")) return;

    var pre = block.querySelector("pre");
    if (!pre) return;

    block.classList.add("code-block");

    var toolbar = document.createElement("div");
    toolbar.className = "code-block__toolbar";

    var language = document.createElement("span");
    language.className = "code-block__language";
    language.textContent = getLanguage(block);

    var button = document.createElement("button");
    button.className = "code-block__copy";
    button.type = "button";
    button.setAttribute("aria-label", "Copy code snippet");
    button.textContent = "Copy";

    button.addEventListener("click", function () {
      var code = pre.innerText.replace(/\n$/, "");
      copyText(code).then(function () {
        button.textContent = "Copied";
        button.classList.add("is-copied");
        window.setTimeout(function () {
          button.textContent = "Copy";
          button.classList.remove("is-copied");
        }, 1600);
      }).catch(function () {
        button.textContent = "Error";
        window.setTimeout(function () {
          button.textContent = "Copy";
        }, 1600);
      });
    });

    toolbar.appendChild(language);
    toolbar.appendChild(button);
    block.insertBefore(toolbar, block.firstChild);
  }

  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll(".page__content pre").forEach(function (pre) {
      var block = pre.closest(".highlighter-rouge") || pre.parentElement;
      if (block) enhanceCodeBlock(block);
    });
  });
}());
