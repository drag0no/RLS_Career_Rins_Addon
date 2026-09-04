-- core_modmanager temporarily wraps extensions.load while executing modScript.
-- Defer installation so the override manager captures BeamNG's real loader,
-- not that short-lived activation wrapper.
core_jobsystem.create(function(job)
  job.sleep(0.25)
  setExtensionUnloadMode("overhaul_extensionManager", "manual")
  extensions.load("overhaul_extensionManager")
  extensions.load("career_saveMigration")
  setExtensionUnloadMode("career_saveMigration", "manual")
end)
