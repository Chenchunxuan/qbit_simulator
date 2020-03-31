%%% Simulating the dynamics of the qbit. This script will establish state
%%% variables, get a trajectory, input that trajectory into a controller to
%%% get commands, and simulate the dynamis subject to those inputs.
%%% Spencer Folk 2020

clear
clc
close all

aero = true;  % This bool determines whether or not we compute aerodynamic forces
animate = false; % Bool for making an animation of the vehicle.
save_animation = false; % Bool for saving the animation as a gif
traj_type = "trim"; % Type of trajectory, "cubic" or "trim" (for steady state flight)

%% Initialize Constants
in2m = 0.0254;
g = 9.81;
rho = 1.2;
eta = 1;   % Efficiency of the down wash on the wings from the propellers

% Ritz tailsitter
% m = 0.150;
% Iyy = 2.32e-3;
% span = 15*in2m;
% l = 6*in2m;
% chord = 5*in2m;
% R = 2.5*in2m;

% UMD QBiT
% m = 3.76;
% Iyy = 2.32e-1;  % Estimated with scaling laws based on mass and chord
% span = 1.02;
% chord = 0.254;
% l = 19*in2m;
% R = 15/2*in2m;

% UMD QBiT Refined (thrust from motors don't even balance the weight...)
% m = 1.264;
% Iyy = 2.32e-2;  % Estimated with scaling laws based on mass and chord
% span = 1.02;
% chord = 0.254;
% l = 19*in2m;
% R = 15/2*in2m;

% CRC 5in prop
% m_airframe = 0.215;
% m_battery = 0.150;
% m = m_airframe + m_battery;
% 
% Iyy = 2.32e-3;
% span = 15*in2m;
% l = 6*in2m;
% chord = 5*in2m;
% R = 2.5*in2m;

% CRC 9in prop (CRC-3 from CAD)
% Compute a scaling factor based on change in wing span:
span = 0.508;
l = 0.244;
chord = 0.087;
R = 4.5*in2m;   % Estimated 9in prop

scaling_factor = span/(15*in2m);
m = (0.3650)*(scaling_factor^3);  % Mass scales with R^3
Iyy = (2.32e-3)*(scaling_factor^5);

% Aero coefficients that act on the lift/drag coefficients to match that of
% "experimental" (in reality, simulation) data from XFOIL

% c0 = 4.80914;  % coeff acts as a scaling factor on Cl, Cm
% c1 = 0.02;     % coeff acts as a shifting factor on Cd
% c2 = 0.61929;  % coeff acts as a scaling factor on Cd

% c0 = 1;
% c1 = 0;
% c2 = 1;

%% Generate Airfoil Look-up
% This look up table data will be used to estimate lift, drag, moment given
% the angle of attack and interpolation from this data.
[cl_spline, cd_spline, cm_spline] = aero_lookup("naca_0015_experimental_Re-160000.csv");

%% Trajectory Generation
% Generate a trajectory based on the method selected. If cubic, use cubic
% splines. If trim, create a constant speed, trim flight.
V_s = 30;
end_time = 10;   % Duration of trajectory, this will be rewritten if cubic spline is selected

if traj_type == "cubic"
    waypoints = [0,40; 0,0];
    % waypoints = [0,0,10 ; 0,10,10];  % aggressive maneuver
    % waypoints = [0,20,40 ; 0,0,0];  % Straight line horizontal trajectory
    % waypoints = [0,80,160 ; 0,0,0];  % Straight line horizontal trajectory, longer
    % waypoints = [0,0,0 ; 0, 20, 40]; % Straight line vertical trajectory
    % waypoints = [0,10,40 ; 0,10,10];  % Larger distance shows off lift benefit
    % waypoints = [0,20,40 ; 0,5,10]; % diagonal
    % waypoints = [0,10,20,30,40 ; 0,10,0,-10,0]; % zigzag
    % waypoints = [0,0 ; 0, -10];  % Drop
    % waypoints = [0,0 ; 0, 10];  % rise
    
    [traj_obj, end_time] = qbit_trajectory_generator(waypoints, V_s);
    
    % Use this traj_obj to get our desired x,z at a given time t
    traj_obj_dot = fnder(traj_obj,1);
    traj_obj_dotdot = fnder(traj_obj,2);
    
    init_conds = [m*g/2; m*g/2 ; pi/2];
elseif traj_type == "trim"
    % In the trim mode, we have to have a good initial guess for the trim
    % condition, so that the QBiT isn't too far from the steady state value
    % at the beginning of the trajectory!
    
    % This involves solving for T_top(0), T_bot(0), phi(0)
    x0 = [m*g/2; m*g/2; pi/4];
    fun = @(x) trim_flight(x, cl_spline, cd_spline, cm_spline, m,g,l, chord, span, rho, eta, R, V_s);
%     options = optimoptions('fsolve','Display','iter');
    options = optimoptions('fsolve','Display','none','PlotFcn',@optimplotfirstorderopt);
    [init_conds,~,~,output] = fsolve(fun,x0,options);
    
%     output.iterations
    
    fprintf("\nTrim estimate solved: \n")
    fprintf("\nT_top = %3.4f",init_conds(1))
    fprintf("\nT_bot = %3.4f",init_conds(2))
    fprintf("\nphi   = %3.4f\n",init_conds(3))
    
    waypoints = [0 , V_s*end_time ; 0, 0];
end

%% Initialize Arrays

% Time vector
dt = 0.01;
t_f = end_time+3;
time = 0:dt:t_f;

% States
x = zeros(size(time));
z = zeros(size(time));
phi = zeros(size(time));

xdot = zeros(size(time));
zdot = zeros(size(time));
phidot = zeros(size(time));

xdotdot = zeros(size(time));
zdotdot = zeros(size(time));
phidotdot = zeros(size(time));

% Inputs

T_top = init_conds(1)*ones(size(time));
T_bot = init_conds(2)*ones(size(time));

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

Fdes = zeros(2,length(time));  % Desired force vector

% Power consumption
Ptop = zeros(size(time));
Pbot = zeros(size(time));

% Initial conditions:
phi(1) = init_conds(3);
x(1) = 0;
z(1) = 0;
if traj_type == "cubic"
    xdot(1) = 0;
elseif traj_type == "trim"
    xdot(1) = V_s;
end
zdot(1) = 0;

% Trajectory state
desired_state = zeros(6,length(time));  % [x, z, xdot, zdot, xdotdot, zdotdot]
desired_state(:,1) = [x(1);z(1);xdot(1);zdot(1);xdotdot(1);zdotdot(1)];

%% Main Simulation

for i = 2:length(time)
    
    % Retrieve the command thrust from desired trajectory
    current_state = [x(i-1), z(i-1), phi(i-1), xdot(i-1), zdot(i-1), phidot(i-1)];
    current_time = time(i);
    
    % Get our desired state at time(i)
    
    if traj_type == "cubic"
        if time(i) < end_time
            xz_temp = ppval(traj_obj,time(i));
            xzdot_temp = ppval(traj_obj_dot,time(i));
            xzdotdot_temp = ppval(traj_obj_dotdot,time(i));
        else
            xz_temp = waypoints(:,end);
            xzdot_temp = [0;0];
            xzdotdot_temp = [0;0];
        end
    elseif traj_type == "trim"
        xzdotdot_temp = [0 ; 0];
        xzdot_temp = [V_s ; 0];
        xz_temp = [V_s*time(i-1) ; 0];
    end
    
    desired_state(:,i) = [xz_temp' , xzdot_temp' , xzdotdot_temp']; % 6x1
    
    % Find the current airspeed and prop wash speed
    Vi(i-1) = sqrt( xdot(i-1)^2 + zdot(i-1)^2 );
    
    % Compute orientations
    if abs(Vi(i-1)) >= 1e-5
        gamma(i-1) = atan2(zdot(i-1), xdot(i-1));  % Inertial orientation
    else
        gamma(i-1) = 0;
    end
    alpha(i-1) = phi(i-1) - gamma(i-1);  % Angle of attack strictly based on inertial speed
    
    % Get prop wash over wing via momentum theory
    T_avg = 0.5*(T_top(i-1) + T_bot(i-1));
    
    %     Vw(i-1) = 1.2*sqrt( T_avg/(8*rho*pi*R^2) );
    Vw(i-1) = eta*sqrt( (Vi(i-1)*cos(phi(i-1)-gamma(i-1)))^2 + (T_avg/(0.5*rho*pi*R^2)) );
    
    % Compute true airspeed over the wings using law of cosines
    Va(i-1) = sqrt( Vi(i-1)^2 + Vw(i-1)^2 + 2*Vi(i-1)*Vw(i-1)*cos( alpha(i-1)) );
    
    % Use this check to avoid errors in asin
    if Va(i-1) >= 1e-5
        alpha_e(i-1) = asin(Vi(i-1)*sin(alpha(i-1))/Va(i-1));
    else
        alpha_e(i-1) = 0;
    end
    
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
    
    L(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*Cl;
    D(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*Cd;
    M_air(i-1) = 0.5*rho*Va(i-1)^2*(chord*span)*chord*Cm;
    
    %     fprintf("\nIndex = %d",i)
    %     if i == 226
    %         xxx = 50;
    %     end
    [T_top(i), T_bot(i), Fdes(:,i)] = qbit_controller(current_state, ...
        desired_state(:,i), L(i-1), D(i-1), M_air(i-1), alpha_e(i-1), m, ...
        Iyy, l);
    
    xdotdot(i) = ((T_top(i) + T_bot(i))*cos(phi(i-1)) - D(i-1)*cos(phi(i-1) - alpha_e(i-1)) - L(i-1)*sin(phi(i-1) - alpha_e(i-1)))/m;
    zdotdot(i) = ( -m*g + (T_top(i) + T_bot(i))*sin(phi(i-1)) - D(i-1)*sin(phi(i-1) - alpha_e(i-1)) + L(i-1)*cos(phi(i-1) - alpha_e(i-1)))/m;
    phidotdot(i) = (M_air(i-1) + l*(T_bot(i) - T_top(i)))/Iyy;
    
    % Euler integration
    xdot(i) = xdot(i-1) + xdotdot(i)*dt;
    zdot(i) = zdot(i-1) + zdotdot(i)*dt;
    phidot(i) = phidot(i-1) + phidotdot(i)*dt;
    
    x(i) = x(i-1) + xdot(i)*dt;
    z(i) = z(i-1) + zdot(i)*dt;
    phi(i) = phi(i-1) + phidot(i)*dt;
    
end

L(end) = L(end-1);
D(end) = D(end-1);
M_air(end) = M_air(end-1);

Va(end) = Va(end-1);
Vi(end) = Vi(end-1);
Vw(end) = Vw(end-1);

alpha(end) = alpha(end-1);
alpha_e(end) = alpha_e(end-1);
gamma(end) = gamma(end-1);

T_top(end) = T_top(end-1);
T_bot(end) = T_bot(end-1);

Fdes(:,end) = Fdes(:,end-1);
Fdes(:,1) = Fdes(:,2);


%% Animation

if animate == true
    h = figure();
    qbit_animate_trajectory(h, time,[x ; z ; phi], desired_state(1,:), desired_state(2,:),Fdes,l, save_animation)
    hold on
    plot(waypoints(1,:),waypoints(2,:),'ko','linewidth',2)
    axis equal
end

%% Plotting
figure()
sgtitle("States")

subplot(3,1,1)
plot(time, x, 'r-','linewidth',1.5)
hold on
plot(time, desired_state(1,:), 'k--', 'linewidth',1)
ylabel('x [m]')
xlim([0,time(end)])
grid on

subplot(3,1,2)
plot(time, z, 'k-','linewidth',1.5)
hold on
plot(time, desired_state(2,:), 'k--', 'linewidth',1)
ylabel('z [m]')
xlim([0,time(end)])
grid on

subplot(3,1,3)
plot(time, phi, 'b-','linewidth',1.5)
hold on
plot(time, ones(size(time))*pi/2, 'k--', 'linewidth', 1)
ylabel('phi [rad]')
xlim([0,time(end)])
xlabel("Time (s)")
grid on

figure()
sgtitle("State Derivatives")

subplot(3,1,1)
plot(time, xdot, 'r-','linewidth',1.5)
hold on
plot(time, desired_state(3,:), 'k--', 'linewidth',1)
ylabel('xdot [m/s]')
xlim([0,time(end)])
grid on

subplot(3,1,2)
plot(time, zdot, 'k-','linewidth',1.5)
hold on
plot(time, desired_state(4,:), 'k--', 'linewidth',1)
ylabel('zdot [m/s]')
xlim([0,time(end)])
grid on

subplot(3,1,3)
plot(time, phidot, 'b-','linewidth',1.5)
ylabel('phidot [rad/s]')
xlim([0,time(end)])
xlabel("Time (s)")
grid on

figure()
sgtitle("Aero Forces/Moments")

subplot(3,1,1)
plot(time, L, 'r-','linewidth',1.5)
ylabel('Lift [N]')
xlim([0,time(end)])
grid on

subplot(3,1,2)
plot(time, D, 'k-','linewidth',1.5)
ylabel('Drag [N]')
xlim([0,time(end)])
grid on

subplot(3,1,3)
plot(time, M_air, 'b-','linewidth',1.5)
ylabel('M_{air} [Nm]')
xlim([0,time(end)])
xlabel("Time (s)")
grid on

figure()
sgtitle("Airflow Over Wing")

subplot(3,1,1)
plot(time, Va, 'r-','linewidth',1.5)
ylabel('V_a [m/s]')
xlim([0,time(end)])
grid on

subplot(3,1,2)
plot(time, Vi, 'k-','linewidth',1.5)
ylabel('V_i [m/s]')
xlim([0,time(end)])
grid on

subplot(3,1,3)
plot(time, Vw, 'b-','linewidth',1.5)
ylabel('V_w [m/s]')
xlim([0,time(end)])
xlabel("Time (s)")
grid on

figure()
titl = strcat("Misc Angles, \eta = ",num2str(eta));
sgtitle(titl)

subplot(3,1,1)
plot(time, alpha, 'r-','linewidth',1.5)
hold on
plot(time, ones(size(time))*pi, 'k--', 'linewidth', 1)
plot(time, ones(size(time))*(-pi), 'k--', 'linewidth', 1)
ylabel('\alpha [rad]')
xlim([0,time(end)])
% xlim([0,18])
grid on

subplot(3,1,2)
plot(time, alpha_e, 'k-','linewidth',1.5)
hold on
plot(time, ones(size(time))*pi, 'k--', 'linewidth', 1)
plot(time, ones(size(time))*(-pi), 'k--', 'linewidth', 1)
plot(time, ones(size(time))*10*pi/180, 'g--', 'linewidth', 1)
ylabel('\alpha_e [rad]')
xlim([0,time(end)])
% xlim([0,18])
maxi = find(alpha_e == max(alpha_e));
% plot(time(maxi),alpha_e(maxi),'ro','linewidth',2)
% text(end_time/2,-1,strcat("(\alpha_e)_{SS} = ",num2str(mean(alpha_e((end-100):end))),"-rad"))
grid on

subplot(3,1,3)
plot(time, gamma, 'b-','linewidth',1.5)
hold on
plot(time, ones(size(time))*pi, 'k--', 'linewidth', 1)
plot(time, ones(size(time))*(-pi), 'k--', 'linewidth', 1)
ylabel('\gamma [rad]')
xlim([0,time(end)])
% xlim([0,18])
xlabel("Time (s)")
grid on

figure()
sgtitle("Thrust Commands")

plot(time, T_top, 'k-', 'linewidth', 1.5)
hold on
plot(time, T_bot, 'r-', 'linewidth', 1.5)
plot(time, 0.5*(T_top + T_bot), 'g-', 'linewidth', 1.5)
xlabel("Time (s)")
ylabel("Thrust (N)")
legend("T_{top}", "T_{bot}", "T_{avg}")
grid on

figure()
title("Desired Thrust Vector")
plot(time, Fdes(1,:),'-','linewidth',1.5)
hold on
plot(time, Fdes(2,:),'-','linewidth',1.5)
normFdes = zeros(size(time));
for i = 1:length(time)
    normFdes(i) = norm(Fdes(:,i));
end
plot(time, normFdes, 'k--','linewidth',1.5)
xlabel("Time (s)")
ylabel("Force (N)")
legend("Fx","Fz","norm(Fdes)")
title("Thrust Vector from Controller")
grid on

fprintf("\nData points of interest: \n")
fprintf("T_top = %3.4f\n",T_top(end))
fprintf("T_bot = %3.4f\n",T_bot(end))
fprintf("phi = %3.4f\n",phi(end))
fprintf("alpha = %3.4f\n",mean(alpha))
fprintf("alpha_e = %3.4f\n",mean(alpha_e))
fprintf("V_w = %3.4f\n",mean(Vw))
fprintf("V_a = %3.4f\n",mean(Va))
fprintf("L = %3.4f\n",mean(L))
fprintf("D = %3.4f\n",mean(D))
fprintf("M_air = %3.4f\n",mean(M_air))

