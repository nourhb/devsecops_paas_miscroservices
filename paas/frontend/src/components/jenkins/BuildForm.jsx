"use client";

import { useEffect, useState } from "react";
import { Bot, Boxes, Rocket, Sparkles, WandSparkles, Workflow } from "lucide-react";

const INITIAL_FORM = {
  projectDescription: "",
  projectGroupName: "",
  projectName: "",
  projectTag: "",
  buildType: "",
  email: "",
  deliveryType: "",
};

const INPUT_CLASS_NAME =
  "mt-2 flex h-11 w-full rounded-xl border border-border/80 bg-background/70 px-3 py-2 text-sm text-foreground shadow-sm placeholder:text-muted transition focus:border-primary/60 focus:outline-none focus:ring-2 focus:ring-primary/40";

function FormField({ id, label, type = "text", value, onChange, placeholder }) {
  return (
    <div>
      <label className="text-sm font-medium text-foreground" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        name={id}
        type={type}
        value={value}
        onChange={onChange}
        placeholder={placeholder}
        className={INPUT_CLASS_NAME}
        autoComplete="off"
        required
      />
    </div>
  );
}

export default function BuildForm({
  onSubmit,
  onSuggest,
  isSubmitting,
  isSuggesting,
  initialValues,
  aiSuggestion,
}) {
  const [formValues, setFormValues] = useState(initialValues || INITIAL_FORM);

  useEffect(() => {
    if (!initialValues) {
      return;
    }

    setFormValues(initialValues);
  }, [initialValues]);

  function handleChange(event) {
    const { name, value } = event.target;

    setFormValues((currentValues) => ({
      ...currentValues,
      [name]: value,
    }));
  }

  async function handleSubmit(event) {
    event.preventDefault();
    await onSubmit({
      projectDescription: formValues.projectDescription.trim(),
      projectGroupName: formValues.projectGroupName.trim(),
      projectName: formValues.projectName.trim(),
      projectTag: formValues.projectTag.trim(),
      buildType: formValues.buildType.trim(),
      email: formValues.email.trim(),
      deliveryType: formValues.deliveryType.trim(),
    });
  }

  async function handleSuggestClick() {
    await onSuggest({
      projectDescription: formValues.projectDescription.trim(),
      projectGroupName: formValues.projectGroupName.trim(),
      projectName: formValues.projectName.trim(),
      projectTag: formValues.projectTag.trim(),
      buildType: formValues.buildType.trim(),
      email: formValues.email.trim(),
      deliveryType: formValues.deliveryType.trim(),
    });
  }

  return (
    <section className="rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.18)] backdrop-blur xl:p-7">
      <div className="mb-6 flex flex-col gap-4 border-b border-border/70 pb-6 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <div className="inline-flex items-center gap-2 rounded-full border border-primary/20 bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
            <Bot className="h-3.5 w-3.5" />
            AI DevOps Assistant
          </div>
          <h2 className="mt-4 text-2xl font-semibold text-foreground">Build Control Center</h2>
          <p className="mt-2 max-w-2xl text-sm text-muted">
            Launch Jenkins jobs, let AI prefill your build parameters, and track execution in real time.
          </p>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-2xl border border-border/70 bg-background/40 p-4">
            <p className="text-xs uppercase tracking-[0.24em] text-muted">Workflow</p>
            <p className="mt-2 flex items-center gap-2 text-sm font-medium text-foreground">
              <Rocket className="h-4 w-4 text-primary" />
              Build to Jenkins
            </p>
          </div>
          <div className="rounded-2xl border border-border/70 bg-background/40 p-4">
            <p className="text-xs uppercase tracking-[0.24em] text-muted">Assist</p>
            <p className="mt-2 flex items-center gap-2 text-sm font-medium text-foreground">
              <Sparkles className="h-4 w-4 text-primary" />
              Suggestions + Analysis
            </p>
          </div>
        </div>
      </div>

      <form className="grid gap-5 md:grid-cols-2" onSubmit={handleSubmit}>
        <div className="md:col-span-2">
          <label className="text-sm font-medium text-foreground" htmlFor="projectDescription">
            Describe Your Project
          </label>
          <textarea
            id="projectDescription"
            name="projectDescription"
            value={formValues.projectDescription}
            onChange={handleChange}
            placeholder="Example: Spring Boot microservice with Maven, Docker image build, SonarQube scan, Dependency Track, and ArgoCD deployment."
            className={`${INPUT_CLASS_NAME} min-h-32 resize-y py-3`}
          />
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={handleSuggestClick}
              disabled={isSuggesting || isSubmitting}
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl border border-border/80 bg-background/70 px-5 text-sm font-medium text-foreground transition hover:border-primary/50 hover:bg-background disabled:cursor-not-allowed disabled:opacity-60"
            >
              <WandSparkles className="h-4 w-4" />
              {isSuggesting ? (
                <>
                  <span className="h-4 w-4 animate-spin rounded-full border-2 border-foreground/30 border-t-foreground" />
                  Generating...
                </>
              ) : (
                "Generate Pipeline Config"
              )}
            </button>
            <p className="text-sm text-muted">
              AI can suggest the build tool, pipeline steps, and Jenkins parameters.
            </p>
          </div>
        </div>

        {aiSuggestion ? (
          <div className="md:col-span-2 rounded-2xl border border-primary/20 bg-primary/5 p-5 text-sm">
            <div className="flex flex-wrap items-center gap-3">
              <span className="inline-flex items-center gap-2 font-semibold text-foreground">
                <Sparkles className="h-4 w-4 text-primary" />
                AI Suggestion
              </span>
              <span className="rounded-full border border-border/80 px-2 py-1 text-xs text-muted">
                Source: {aiSuggestion.source}
              </span>
            </div>
            <p className="mt-2 text-muted">{aiSuggestion.reasoning}</p>
            <div className="mt-4 grid gap-3 md:grid-cols-3">
              <div className="rounded-xl border border-border/60 bg-background/40 p-4">
                <p className="text-xs uppercase tracking-wide text-muted">Project Name</p>
                <p className="mt-1 font-medium text-foreground">{aiSuggestion.projectName}</p>
              </div>
              <div className="rounded-xl border border-border/60 bg-background/40 p-4">
                <p className="text-xs uppercase tracking-wide text-muted">Build Type</p>
                <p className="mt-1 font-medium text-foreground">{aiSuggestion.buildType}</p>
              </div>
              <div className="rounded-xl border border-border/60 bg-background/40 p-4">
                <p className="text-xs uppercase tracking-wide text-muted">Delivery Type</p>
                <p className="mt-1 font-medium text-foreground">{aiSuggestion.deliveryType}</p>
              </div>
            </div>
            <div className="mt-3 grid gap-3 md:grid-cols-[1fr_2fr]">
              <div className="rounded-xl border border-border/60 bg-background/40 p-4">
                <p className="flex items-center gap-2 text-xs uppercase tracking-wide text-muted">
                  <Boxes className="h-3.5 w-3.5" />
                  Build Tool
                </p>
                <p className="mt-1 font-medium text-foreground">{aiSuggestion.buildTool}</p>
              </div>
              <div className="rounded-xl border border-border/60 bg-background/40 p-4">
                <p className="flex items-center gap-2 text-xs uppercase tracking-wide text-muted">
                  <Workflow className="h-3.5 w-3.5" />
                  Suggested Pipeline
                </p>
                <div className="mt-3 flex flex-wrap gap-2">
                  {(aiSuggestion.pipelineSteps || []).map((step) => (
                    <span
                      key={step}
                      className="rounded-full border border-border/70 bg-background/60 px-3 py-1 text-xs text-foreground"
                    >
                      {step}
                    </span>
                  ))}
                </div>
              </div>
            </div>
            <div className="mt-3 rounded-xl border border-border/60 bg-background/40 p-4">
              <p className="text-xs uppercase tracking-wide text-muted">Jenkins Parameters</p>
              <div className="mt-3 grid gap-3 md:grid-cols-3">
                <div>
                  <p className="text-xs text-muted">projectName</p>
                  <p className="mt-1 font-medium text-foreground">
                    {aiSuggestion.jenkinsParameters?.projectName || aiSuggestion.projectName}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-muted">buildType</p>
                  <p className="mt-1 font-medium text-foreground">
                    {aiSuggestion.jenkinsParameters?.buildType || aiSuggestion.buildType}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-muted">deliveryType</p>
                  <p className="mt-1 font-medium text-foreground">
                    {aiSuggestion.jenkinsParameters?.deliveryType || aiSuggestion.deliveryType}
                  </p>
                </div>
              </div>
            </div>
          </div>
        ) : null}

        <FormField
          id="projectGroupName"
          label="Project Group Name"
          value={formValues.projectGroupName}
          onChange={handleChange}
          placeholder="e.g. core-platform"
        />
        <FormField
          id="projectName"
          label="Project Name"
          value={formValues.projectName}
          onChange={handleChange}
          placeholder="e.g. payments-service"
        />
        <FormField
          id="projectTag"
          label="Project Tag"
          value={formValues.projectTag}
          onChange={handleChange}
          placeholder="e.g. v1.0.0"
        />
        <FormField
          id="buildType"
          label="Build Type"
          value={formValues.buildType}
          onChange={handleChange}
          placeholder="e.g. release"
        />
        <FormField
          id="email"
          label="Email"
          type="email"
          value={formValues.email}
          onChange={handleChange}
          placeholder="team@example.com"
        />
        <FormField
          id="deliveryType"
          label="Delivery Type"
          value={formValues.deliveryType}
          onChange={handleChange}
          placeholder="e.g. internal"
        />

        <div className="md:col-span-2">
          <button
            type="submit"
            disabled={isSubmitting}
            className="inline-flex h-11 min-w-32 items-center justify-center rounded-xl bg-primary px-5 text-sm font-medium text-background shadow-[0_10px_30px_rgba(0,160,180,0.25)] transition hover:translate-y-[-1px] hover:opacity-95 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {isSubmitting ? (
              <>
                <span className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-background/35 border-t-background" />
                Building...
              </>
            ) : (
              "Build"
            )}
          </button>
        </div>
      </form>
    </section>
  );
}
