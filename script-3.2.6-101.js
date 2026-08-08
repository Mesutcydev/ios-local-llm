(() => {
  const root = document.documentElement;

  const setBuildMetadata = (metadata) => {
    if (!metadata) return;
    root.dataset.buildVersion = metadata.version || "";
    root.dataset.buildNumber = metadata.build || "";
    document.querySelectorAll("[data-build]").forEach((element) => {
      element.textContent = metadata.version || element.textContent;
    });
    document.querySelectorAll("[data-build-number]").forEach((element) => {
      element.textContent = metadata.build || element.textContent;
    });
  };

  fetch("site-assets/build.json", { cache: "no-store" })
    .then((response) => response.ok ? response.json() : null)
    .then(setBuildMetadata)
    .catch(() => {});

  const revealItems = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries, instance) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        instance.unobserve(entry.target);
      });
    }, { threshold: 0.12 });
    revealItems.forEach((item) => observer.observe(item));
  } else {
    revealItems.forEach((item) => item.classList.add("is-visible"));
  }

  const dialog = document.querySelector("#preview-dialog");
  const dialogImage = document.querySelector("#preview-dialog-image");
  document.querySelectorAll("[data-preview-image]").forEach((trigger) => {
    trigger.addEventListener("click", () => {
      if (!dialog || !dialogImage) return;
      dialogImage.src = trigger.dataset.previewImage;
      dialogImage.alt = trigger.dataset.previewAlt || "App preview";
      if (typeof dialog.showModal === "function") dialog.showModal();
      else dialog.setAttribute("open", "");
    });
  });

  dialog?.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });
})();
