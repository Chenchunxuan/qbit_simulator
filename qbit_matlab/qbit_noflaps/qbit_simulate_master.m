%%% Simulating the dynamics of the qbit. This script will establish state
%%% variables, get a trajectory, input that trajectory into a controller to
%%% get commands, and simulate the dynamics subject to those inputs.
%%% Spencer Folk 2020

clear
clc
close all

% Bools / Settings
aero = true;  % This bool determines whether or not we compute aerodynamic forces
animate = false; % Bool for making an animation of the vehicle.
save_animation = true; % Bool for saving the animation as a gif
integrate_method = "rk4";  % Type of integration - either 'euler' or 'rk4'
traj_type = "trim"; % Type of trajectory:
%                           "cubic",
%                           "trim" (for steady state flight),
%                           "increasing" (const acceleration)
%                           "decreasing" (const decelleration)
%                           "prescribed_aoa" (constant height, continuous AoA)
%                           "stepP" (step response in position at hover)
%                           "stepA_hover" (step response in angle at hover)
%                           "stepV" (step response in airspeed at trim)
%                           "stepA_FF" (step response in angle at forward flight)

%% Initialize Constants
in2m = 0.0254;
g = 9.81;
rho = 1.2;
stall_angle = 10;  % deg, identified from plot of cl vs alpha
dt = 0.01;   % Simulation time step

eta = 0.0;   % Efficiency of the down wash on the wings from the propellers

linear_acc = 2;   % m/s^2, the acceleration/decelleration used in
%                  "increasing" and "decreasing" trajectories
angular_vel = -1;   % deg/s, the desired change in attitude used by the
%                  "prescribed_aoa" trajectory
V_s = 25;          % m/s, set velocity used in "increasing", "decreasing", and
%                  "trim" trajectories...
end_time = 5;     % Duration of trajectory, this will be REWRITTEN by all but
%                  "trim" and "step___" trajectories.

step_angle = -pi/4; % the angular step used by stepA_hover (positive counter clockwise)
step_y = -1;          % step in the x direction used by stepP
step_z = -1;          % step in the z direction used by stepP
step_V = -3;          % step in forward airspeed used by stepV

buffer_time = 4;  % s, sim time AFTER transition maneuver theoretically ends
%                   ... this is to capture settling of the controller

%% Vehicle Parameters
% Load in physical parameters for the qbit

% CRC 5in prop
% m_airframe = 0.215;
% m_battery = 0.150;
% m = m_airframe + m_battery;
%
% Ixx = 2.32e-3;
% span = 15*in2m;
% l = 6*in2m;
% chord = 5*in2m;
% R = 2.5*in2m;

% CRC 9in prop (CRC-3 from CAD)
% Compute a scaling factor based on change in wing span:
span = 2*0.508;  % Doubled for biplane set up
l = 0.244;
chord = 0.087;
R = 4.5*in2m;   % Estimated 9in prop

scaling_factor = span/(15*in2m);
% m = (0.3650)*(scaling_factor^3);  % Mass scales with R^3
m = 0.8652;  % This is the value of expression above^ but we want it fixed
%              so we can change the span without worry
% Ixx = (2.32e-3)*(scaling_factor^5);
Ixx = 0.009776460905350; % This is the value of expression above^ but we want it fixed
%                          so we can change the span without worry

%% Generate Airfoil Look-up
% This look up table data will be used to estimate lift, drag, moment given
% the angle of attack and interpolation from this data.
[cl_spline, cd_spline, cm_spline] = aero_fns("naca_0015_experimental_Re-160000.csv");

%% Trajectory Generation
% Generate a trajectory based on the method selected. If cubic, use cubic
% splines. If trim, create a constant speed, trim flight.

if traj_type == "cubic"
    %     waypoints = [0,40; 0,0];
    % waypoints = [0,0,10 ; 0,10,10];  % aggressive maneuver
    % waypoints = [0,20,40 ; 0,0,0];  % Straight line horizontal trajectory
    waypoints = [0,80,160 ; 0,0,0];  % Straight line horizontal trajectory, longer
    % waypoints = [0,0,0 ; 0, 20, 40]; % Straight line vertical trajectory
    % waypoints = [0,10,40 ; 0,10,10];  % Larger distance shows off lift benefit
    % waypoints = [0,20,40 ; 0,5,10]; % diagonal
    % waypoints = [0,10,20,30,40 ; 0,10,0,-10,0]; % zigzag
    % waypoints = [0,0 ; 0, -10];  % Drop
    % waypoints = [0,0 ; 0, 10];  % rise
    
    [traj_obj, end_time] = qbit_spline_generator(waypoints, V_s);
    
    % Use this traj_obj to get our desired y,z at a given time t
    traj_obj_dot = fnder(traj_obj,1);
    traj_obj_dotdot = fnder(traj_obj,2);
    
    init_conds = [m*g/2; m*g/2 ; pi/2];
    
    % Time vector
    t_f = end_time;
    time = 0:dt:t_f;
    
    fprintf("\nTrajectory type: Cubic Spline")
    fprintf("\n-----------------------------\n")
    
elseif traj_type == "trim"
    % In the trim mode, we have to have a good initial guess for the trim
    % condition, so that the QBiT isn't too far from the steady state value
    % at the beginning of the trajectory!
    
    % This involves solving for T_top(0), T_bot(0), theta(0)
    x0 = [m*g/2; m*g/2; pi/4];
    fun = @(x) trim_flight(x, cl_spline, cd_spline, cm_spline, m,g,l, chord, span, rho, eta, R, V_s);
    %     options = optimoptions('fsolve','Display','iter');
    options = optimoptions('fsolve','Display','none','PlotFcn',@optimplotfirstorderopt);
    [init_conds,~,~,output] = fsolve(fun,x0,options);
    
    %     output.iterations
    
    % Time vector
    t_f = end_time;
    time = 0:dt:t_f;
    
    fprintf("\nTrajectory type: Trim")
    fprintf("\n---------------------\n")
    fprintf("\nTrim estimate solved: \n")
    fprintf("\nT_top = %3.4f",init_conds(1))
    fprintf("\nT_bot = %3.4f",init_conds(2))
    fprintf("\ntheta   = %3.4f\n",init_conds(3))
    
    waypoints = [0 , V_s*end_time ; 0, 0];
elseif traj_type == "increasing"
    % In this mode we use a constant acceleration to go from hover to V_s.
    % Therefore just set the initial condition to 0.
    
    init_conds = [m*g/2; m*g/2 ; pi/2];
    V_end = V_s;
    a_s = linear_acc;  % m/s^2, acceleration used for transition
    
    end_time = V_end/a_s + buffer_time;
    
    % Time vector
    t_f = end_time;
    time = 0:dt:t_f;
    
    fprintf("\nTrajectory type: Linear Increasing")
    fprintf("\n----------------------------------\n")
    
elseif traj_type == "decreasing"
    % Constant deceleration from some beginning speed, V_start, to hover.
    
    % Need to solve for an estimate of trim flight:
    x0 = [m*g/2; m*g/2; pi/4];
    fun = @(x) trim_flight(x, cl_spline, cd_spline, cm_spline, m,g,l, chord, span, rho, eta, R, V_s);
    %     options = optimoptions('fsolve','Display','iter');
    options = optimoptions('fsolve','Display','none','PlotFcn',@optimplotfirstorderopt);
    [init_conds,~,~,output] = fsolve(fun,x0,options);
    
    V_start = V_s;
    a_s = linear_acc;   % m/s^2, decelleration used for transition
    end_time = V_start/a_s + buffer_time;
    
    % Time vector
    t_f = end_time;
    time = 0:dt:t_f;
    
    fprintf("\nTrajectory type: Linear Decreasing")
    fprintf("\n----------------------------------\n")
    
elseif traj_type == "prescribed_aoa"
    % If it's constant height, design a desired AoA function
    % return a corresponding v(t), a(t), y/z(t) from that.
    
    % Need to solve for an estimate of trim flight:
    %     x0 = [m*g/2; m*g/2; 0];
    %     fun = @(x) trim_flight(x, cl_spline, cd_spline, cm_spline, m,g,l, chord, span, rho, eta, R, V_s);
    %     %     options = optimoptions('fsolve','Display','iter');
    %     options = optimoptions('fsolve','Display','none');
    %     [init_conds,~,~,output] = fsolve(fun,x0,options);
    
    a_v = 1/2*rho*chord*span*V_s^2/(m*g);
    x0 = 1e-3;
    options = optimoptions('fsolve','Display','none');
    
    fun = @(x) a_v - cot(x)/(ppval(cd_spline, x*180/pi) + ppval(cl_spline, x*180/pi)*cot(x));
    
    [init_conds,~,~,output] = fsolve(fun, x0, options);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Constructing alpha_des:
    alpha_f = init_conds(end);  % Final value for alpha_des
    alpha_i = pi/2;  % Initial value for alpha_des
    
    alpha_traj_type = "parabolic";
    if alpha_traj_type == "linear"
        aoa_rate = angular_vel*(pi/180);  % Rate of change of AoA, first number in degrees
        end_time = abs(alpha_f - alpha_i)/abs(aoa_rate) + buffer_time;
        t_f = end_time;
        time = 0:dt:t_f;
        
        alpha_des = alpha_i + aoa_rate*time;
        alpha_des(time>(end_time-buffer_time)) = alpha_f;
    elseif alpha_traj_type == "parabolic"
        vertex_time = 97;    % seconds, time location of the vertex of parabola
        end_time = vertex_time + buffer_time;  % seconds
        t_f = end_time;
        time = 0:dt:t_f;
        
        a_coeff = (alpha_i - alpha_f)/((end_time-buffer_time)^2);
        alpha_des = alpha_f + a_coeff*(time-(end_time-buffer_time)).^2;
        alpha_des(time>(end_time-buffer_time)) = alpha_f;
        
    elseif alpha_traj_type == "decay"
        aoa_tau = 5;                        % seconds, time constant of first order decay
        %                                     used in alpha_traj_type = "decay"
        end_time = 4*aoa_tau + buffer_time; % seconds, we choose this.
        t_f = end_time;
        time = 0:dt:t_f;
        
        alpha_des = alpha_f + (alpha_i - alpha_f)*exp(-time./aoa_tau);
    end
    
    % Get temp trajectory variables and save them
    accel_bool = true;  % Consider acceleration when generating the trajectory
    [y_des, ydot_des, ydotdot_des]=prescribed_aoa_traj_generator(dt,time,alpha_des,cl_spline, cd_spline,rho,m,g,chord,span, accel_bool);
    
    fprintf("\nTrajectory type: Prescribed AoA")
    fprintf("\n-------------------------------\n")
    
elseif traj_type == "stepP" || traj_type == "stepA_hover"
    % For step hover, this is easy, we just need to set our trajectory to
    % zeros for all time
    time = 0:dt:end_time;
    
    fprintf("\nTrajectory type: Step Response at Hover")
    fprintf("\n---------------------------------------\n")
    
elseif traj_type == "stepV" || traj_type == "stepA_FF"
    % For the step in airspeed, we need to first set trim just like "trim"
    x0 = [m*g/2; m*g/2; pi/4];
    fun = @(x) trim_flight(x, cl_spline, cd_spline, cm_spline, m,g,l, chord, span, rho, eta, R, V_s);
    %     options = optimoptions('fsolve','Display','iter');
    options = optimoptions('fsolve','Display','none','PlotFcn',@optimplotfirstorderopt);
    [init_conds,~,~,output] = fsolve(fun,x0,options);
    
    %     output.iterations
    
    % Time vector
    t_f = end_time;
    time = 0:dt:t_f;
    
    fprintf("\nTrajectory type: Step in Flight")
    fprintf("\n-------------------------------\n")
else
    error("Incorrect trajectory type -- check traj_type variable")
end

fprintf(strcat("Integration Method: ",integrate_method));
fprintf(strcat("\nStep size: ",num2str(dt),"-sec"));
fprintf("\n----------------------------------\n")

%% Initialize Arrays

%%% TIME IS INTITALIZED IN THE SECTION ABOVE

% States
y = zeros(size(time));
z = zeros(size(time));
theta = zeros(size(time));

ydot = zeros(size(time));
zdot = zeros(size(time));
thetadot = zeros(size(time));

ydotdot = zeros(size(time));
zdotdot = zeros(size(time));
thetadotdot = zeros(size(time));

% Inputs

if traj_type == "trim" || traj_type == "decreasing"
    T_top = init_conds(1)*ones(size(time));
    T_bot = init_conds(2)*ones(size(time));
    
else
    T_top = m*g*ones(size(time));
    T_bot = m*g*ones(size(time));
end
% Misc Variables (also important)
alpha = zeros(size(time));
alpha_e = zeros(size(time));
gamma = zeros(size(time));

L = zeros(size(time));
D = zeros(size(time));
M_air = zeros(size(time));

Vi = zeros(size(time));
Va = zeros(size(time));
Vw = zeros(size(time));

% Bookkeeping the airflow over the top and bottom wings
Vw_top = zeros(size(time));
Vw_bot = zeros(size(time));

Fdes = zeros(2,length(time));  % Desired force vector
rdotdot_des = zeros(2,length(time));

% Power consumption
Ptop = zeros(size(time));
Pbot = zeros(size(time));

% Initial conditions:
theta(1) = pi/2;
y(1) = 0;
z(1) = 0;
if traj_type == "trim" || traj_type == "decreasing"
    ydot(1) = V_s;
    theta(1) = init_conds(3);
elseif traj_type == "stepV"
    ydot(1) = V_s + step_V;
    theta(1) = init_conds(3);
elseif traj_type == "stepA_FF"
    ydot(1) = V_s;
    theta(1) = init_conds(3) + step_angle;
elseif traj_type == "stepP"
    y(1) = step_y;
    z(1) = step_z;
elseif traj_type == "stepA_hover"
    theta(1) = pi/2 + step_angle;
end
zdot(1) = 0;

% Trajectory state
desired_state = zeros(6,length(time));  % [y, z, ydot, zdot, ydotdot, zdotdot]
desired_state(:,1) = [y(1);z(1);ydot(1);zdot(1);ydotdot(1);zdotdot(1)];

%% Main Simulation

for i = 2:length(time)
    
    % Retrieve the command thrust from desired trajectory
    current_state = [y(i-1), z(i-1), theta(i-1), ydot(i-1), zdot(i-1), thetadot(i-1)];
    current_time = time(i);
    
    % Get our desired state at time(i)
    
    if traj_type == "cubic"
        if time(i) < end_time
            yz_temp = ppval(traj_obj,time(i));
            yzdot_temp = ppval(traj_obj_dot,time(i));
            yzdotdot_temp = ppval(traj_obj_dotdot,time(i));
        else
            yz_temp = waypoints(:,end);
            yzdot_temp = [0;0];
            yzdotdot_temp = [0;0];
        end
    elseif traj_type == "trim" || traj_type == "stepV" || traj_type == "stepA_FF"
        yzdotdot_temp = [0 ; 0];
        yzdot_temp = [V_s ; 0];
        yz_temp = [V_s*time(i-1) ; 0];
    elseif traj_type == "increasing"
        if time(i) < (end_time-buffer_time)
            yzdotdot_temp = [a_s ; 0];
            yzdot_temp = [a_s*time(i-1) ; 0];
            yz_temp = [(1/2)*a_s*(time(i-1)^2) ; 0];
        else
            yzdotdot_temp = [0 ; 0];
            yzdot_temp = [V_s ; 0];
            yz_temp = [(1/2)*a_s*((end_time-buffer_time)^2) + V_s*(time(i) - (end_time-buffer_time)) ; 0];
        end
    elseif traj_type == "decreasing"
        if time(i) < (end_time-buffer_time)
            yzdotdot_temp = [-a_s ; 0];
            yzdot_temp = [V_start-a_s*time(i-1) ; 0];
            yz_temp = [V_start*time(i-1)-(1/2)*a_s*(time(i-1)^2) ; 0];
        else
            yzdotdot_temp = [0 ; 0];
            yzdot_temp = [0 ; 0];
            yz_temp = [V_start*(end_time-buffer_time) - 0.5*a_s*(end_time-buffer_time)^2 ; 0];
        end
    elseif traj_type == "prescribed_aoa"
        % Take the trajectory generation section and read from there
        time_temp = round(end_time-buffer_time-dt,2);
        if time(i) < (end_time-buffer_time)
            yzdotdot_temp = [ydotdot_des(i); 0];
            yzdot_temp = [ydot_des(i); 0];
            yz_temp = [y_des(i); 0];
        else
            yzdotdot_temp = [0;0];
            yzdot_temp = [V_s ; 0];
            yz_temp = [y(time == time_temp) + V_s*(time(i) - (end_time-buffer_time)) ; 0];
        end
    elseif traj_type == "stepA_hover" || traj_type == "stepP"
        yzdotdot_temp = [0 ; 0];
        yzdot_temp = [0 ; 0];
        yz_temp = [0 ; 0];
    end
    
    desired_state(:,i) = [yz_temp' , yzdot_temp' , yzdotdot_temp']; % 6x1
    
    % Find the current airspeed and prop wash speed
    Vi(i-1) = sqrt( ydot(i-1)^2 + zdot(i-1)^2 );
    
    % Compute orientations
    if abs(Vi(i-1)) >= 1e-10
        gamma(i-1) = atan2(zdot(i-1), ydot(i-1));  % Inertial orientation
    else
        gamma(i-1) = 0;
    end
    alpha(i-1) = theta(i-1) - gamma(i-1);  % Angle of attack strictly based on inertial speed
    
    % Get prop wash over wing via momentum theory
    T_avg = 0.5*(T_top(i-1) + T_bot(i-1));
    
    %     Vw(i-1) = 1.2*sqrt( T_avg/(8*rho*pi*R^2) );
    Vw(i-1) = eta*sqrt( (Vi(i-1)*cos(theta(i-1)-gamma(i-1)))^2 + (T_avg/(0.5*rho*pi*R^2)) );
    Vw_top(i-1) = eta*sqrt( (Vi(i-1)*cos(theta(i-1)-gamma(i-1)))^2 + (T_top(i-1)/(0.5*rho*pi*R^2)) );
    Vw_bot(i-1) = eta*sqrt( (Vi(i-1)*cos(theta(i-1)-gamma(i-1)))^2 + (T_bot(i-1)/(0.5*rho*pi*R^2)) );
    
    % Compute true airspeed over the wings using law of cosines
    Va(i-1) = sqrt( Vi(i-1)^2 + Vw(i-1)^2 + 2*Vi(i-1)*Vw(i-1)*cos( alpha(i-1)) );
    
    % Use this check to avoid errors in asin
    if Va(i-1) >= 1e-10
        alpha_e(i-1) = asin(Vi(i-1)*sin(alpha(i-1))/Va(i-1));
    else
        alpha_e(i-1) = 0;
    end
    
    % Retrieve aero coefficients based on angle of attack
    if aero == true
        %         [Cl, Cd, Cm] = aero_fns(c0, c1, c2, alpha_e(i-1));
        %         Cl = interp1(alpha_data, cl_data, alpha_e(i-1)*180/pi);
        %         Cd = interp1(alpha_data, cd_data, alpha_e(i-1)*180/pi);
        %         Cm = interp1(alpha_data, cm_data, alpha_e(i-1)*180/pi);
        Cl = ppval(cl_spline, alpha_e(i-1)*180/pi);
        Cd = ppval(cd_spline, alpha_e(i-1)*180/pi);
        Cm = ppval(cm_spline, alpha_e(i-1)*180/pi);
    else
        Cl = 0;
        Cd = 0;
        Cm = 0;
        alpha_e(i-1) = alpha(i-1);  % The traditional angle of attack is now true.
    end
    
    % Compute aero forces/moments
    L(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*Cl;
    D(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*Cd;
    M_air(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*chord*Cm;
    
    
    % Controller
    [T_top(i), T_bot(i), Fdes(:,i), rdotdot_des(:,i)] = qbit_controller(current_state, ...
        desired_state(:,i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1), m, ...
        Ixx, l);
    
    if integrate_method == "euler"
        %%%%%%%%%% Euler Integration
        ydotdot(i) = ((T_top(i) + T_bot(i))*cos(theta(i-1)) - D(i-1)*cos(theta(i-1) - alpha_e(i-1)) - L(i-1)*sin(theta(i-1) - alpha_e(i-1)))/m;
        zdotdot(i) = ( -m*g + (T_top(i) + T_bot(i))*sin(theta(i-1)) - D(i-1)*sin(theta(i-1) - alpha_e(i-1)) + L(i-1)*cos(theta(i-1) - alpha_e(i-1)))/m;
        thetadotdot(i) = (M_air(i-1) + l*(T_bot(i) - T_top(i)))/Ixx;
        
        % Euler integration
        ydot(i) = ydot(i-1) + ydotdot(i)*dt;
        zdot(i) = zdot(i-1) + zdotdot(i)*dt;
        thetadot(i) = thetadot(i-1) + thetadotdot(i)*dt;
        
        y(i) = y(i-1) + ydot(i)*dt;
        z(i) = z(i-1) + zdot(i)*dt;
        theta(i) = theta(i-1) + thetadot(i)*dt;
        
    elseif integrate_method == "rk4"
        %%%%%%%%%%% 4th-Order Runge Kutta:
        state = [y(i-1);z(i-1);theta(i-1);ydot(i-1);zdot(i-1);thetadot(i-1)];
        k1 = dynamics(state, m, g, Ixx, l, T_top(i), T_bot(i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1));
        k2 = dynamics(state+(dt/2)*k1, m, g, Ixx, l, T_top(i), T_bot(i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1));
        k3 = dynamics(state+(dt/2)*k2, m, g, Ixx, l, T_top(i), T_bot(i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1));
        k4 = dynamics(state+(dt)*k3, m, g, Ixx, l, T_top(i), T_bot(i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1));
        
        new_state = state + (dt/6)*(k1 + 2*k2 + 2*k3 + k4);
        y(i) = new_state(1);
        z(i) = new_state(2);
        theta(i) = new_state(3);
        ydot(i) = new_state(4);
        zdot(i) = new_state(5);
        thetadot(i) = new_state(6);
        
        ydotdot(i) = k1(4);
        zdotdot(i) = k1(5);
        thetadotdot(i) = k1(6);
    else
        errordlg("Incorrect integration scheme")
    end
end

% Padding
L(end) = L(end-1);
D(end) = D(end-1);
M_air(end) = M_air(end-1);

Va(end) = Va(end-1);
Vi(end) = Vi(end-1);
Vw(end) = Vw(end-1);
Vw_top(end) = Vw_top(end-1);
Vw_bot(end) = Vw_bot(end-1);

alpha(end) = alpha(end-1);
alpha_e(end) = alpha_e(end-1);
gamma(end) = gamma(end-1);

T_top(end) = T_top(end-1);
T_bot(end) = T_bot(end-1);

Fdes(:,end) = Fdes(:,end-1);
Fdes(:,1) = Fdes(:,2);

alpha_e_startidx = find(alpha_e ~= 0,1,'first');
alpha_e(1:(alpha_e_startidx-1)) = alpha_e(alpha_e_startidx);

Va(1) = Va(2);
Vw(1) = Vw(2);
Vw_top(1) = Vw_top(2);
Vw_bot(1) = Vw_bot(2);
T_top(1) = T_top(2);
T_bot(1) = T_bot(2);
ydotdot(1) = ydotdot(2);
zdotdot(1) = zdotdot(2);

a_v_Va = (1/2)*rho*(chord*span)*Va.^2/(m*g);

%% Trim Comparison
% Take the data from the trim analysis for the particular flight condition
% we're interested in (based on eta)

table = readtable("prop_wash_sweep.csv");
trim_eta = table.eta;
trim_alpha_e = table.alpha_e(trim_eta == eta);
trim_theta = table.theta(trim_eta == eta);
trim_alpha = table.alpha(trim_eta == eta);
trim_Vi = table.V_i(trim_eta == eta);
trim_a_v_Va = table.a_v_Va(trim_eta == eta);
trim_Cl = table.Cl(trim_eta == eta);
trim_Cd = table.Cd(trim_eta == eta);

if traj_type == "increasing" || traj_type == "decreasing"
    % Apply the acceleration shift based on derivation of a_v relationship
    % with alpha.
    if traj_type == "decreasing"
        a_s = -a_s;
    end
    trim_a_v_Va_shift = trim_a_v_Va - (a_s/g)./(trim_Cd + trim_Cl.*cot(trim_alpha_e*pi/180));
end

%% Plotting
qbit_main_plotting()


%% Dynamics Function
function xdot = dynamics(x, m, g, Ixx, l, T_top, T_bot, L, D, M_air, alpha_e)
% INPUTS
% t - current time (time(i))
% x - current state , x = [6x1] = [y, z, theta, ydot, zdot, thetadot]
% m, g, Ixx, l - physical parameters of mass, gravity, inertia, prop arm
% length
% T_top, T_bot - motor thrust inputs
% L, D, M_air - aero forces and moments, computed prior
% alpha_e - effective AoA on the wing

xdot = zeros(size(x));

xdot(1) = x(4);
xdot(2) = x(5);
xdot(3) = x(6);
xdot(4) = ((T_top + T_bot)*cos(x(3)) - D*cos(x(3) - alpha_e) - L*sin(x(3) - alpha_e))/m;
xdot(5) = ( -m*g + (T_top + T_bot)*sin(x(3)) - D*sin(x(3) - alpha_e) + L*cos(x(3) - alpha_e))/m;
xdot(6) = (M_air + l*(T_bot - T_top))/Ixx;

end