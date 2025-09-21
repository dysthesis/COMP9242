{ pkgs, ... }:
let

  pyPkgs = pkgs.python3Packages;

  pyfdt = pyPkgs.buildPythonPackage rec {
    pname = "pyfdt";
    version = "0.3";
    src = pyPkgs.fetchPypi {
      inherit pname version;
      sha256 = "1w7lp421pssfgv901103521qigwb12i6sk68lqjllfgz0lh1qq31";
    };
  };

  autopep8_1_4_3 = pyPkgs.buildPythonPackage rec {
    pname = "autopep8";
    version = "1.4.3";
    src = pyPkgs.fetchPypi {
      inherit pname version;
      sha256 = "13140hs3kh5k13yrp1hjlyz2xad3xs1fjkw1811gn6kybcrbblik";
    };
    propagatedBuildInputs = [ pyPkgs.pycodestyle ];
    checkInputs = [ pkgs.glibcLocales ];
    LC_ALL = "en_US.UTF-8";
    doCheck = false;
  };

  cmake-format = pyPkgs.buildPythonPackage rec {
    pname = "cmake_format";
    version = "0.4.5";
    src = pyPkgs.fetchPypi {
      inherit pname version;
      sha256 = "0nl78yb6zdxawidp62w9wcvwkfid9kg86n52ryg9ikblqw428q0n";
    };
    propagatedBuildInputs = [
      pyPkgs.jinja2
      pyPkgs.pyyaml
    ];
    doCheck = false;
  };

  guardonce = pyPkgs.buildPythonPackage rec {
    pname = "guardonce";
    version = "2.4.0";
    src = pyPkgs.fetchPypi {
      inherit pname version;
      sha256 = "0sr7c1f9mh2vp6pkw3bgpd7crldmaksjfafy8wp5vphxk98ix2f7";
    };
    buildInputs = [ pyPkgs.nose ];
  };

  # The actual package you want
  sel4Deps = pyPkgs.buildPythonPackage rec {
    pname = "sel4-deps";
    version = "0.3.1";
    src = pyPkgs.fetchPypi {
      inherit pname version;
      sha256 = "09xjv4gc9cwanxdhpqg2sy2pfzn2rnrnxgjdw93nqxyrbpdagd5r";
    };
    postPatch = ''
      substituteInPlace setup.py --replace bs4 beautifulsoup4
    '';
    propagatedBuildInputs = with pyPkgs; [
      six
      future
      jinja2
      lxml
      ply
      psutil
      beautifulsoup4
      sh
      pexpect
      pyaml
      jsonschema
      pyfdt
      cmake-format
      guardonce
      autopep8_1_4_3
      pyelftools
      libarchive-c
      setuptools
    ];
  };
in
sel4Deps
