%% This is the application resource file (.app file) for the erlfaye_demo,
%% application.
{application, erlfaye_demo,
  [{description, "A sample app for the erlfaye server"},
   {vsn, "1.0.0"},
   {modules, [erlfaye_demo_app,
              erlfaye_demo_sup]},
   {registered,[erlfaye_demo_sup]},
   {applications, [kernel, stdlib]},
   {mod, {erlfaye_demo_app,[]}},
   {start_phases, []}]}.

